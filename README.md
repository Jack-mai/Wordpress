# WordPress trên Kubernetes + CI/CD

WordPress chạy trên cụm K8s (3 master + 3 worker). **Toàn bộ dữ liệu nằm trên máy riêng `10.10.90.149`**: database MySQL và ảnh/file upload (NFS). Pod WordPress không giữ dữ liệu, nên chạy được 3 bản cùng lúc và deploy không gián đoạn.

```
                     Người dùng
                         │  https://10.10.90.151   (/argocd, /jenkins)
                         ▼
┌──────────────────── Cluster K8s ─────────────────────┐
│  Traefik (IP ảo 10.10.90.151, MetalLB)               │
│      │                                               │
│      ▼                                               │
│  WordPress × 3 pod  ◄── Argo CD deploy Helm chart ◄──┼── GitHub: Jack-mai/Wordpress (gitops/wordpress)
│      │       │                       ▲               │              ▲
│      │       │          (Phần B)     │ sửa image tag │              │
│      │       │          Jenkins ─────┴───────────────┼──────────────┘
│      │       │             ▲  build image → GHCR     │
└──────┼───────┼─────────────┼─────────────────────────┘
       │       │             └── GitHub: Jack-mai/wordpress-app (code, Dockerfile, Jenkinsfile)
       ▼       ▼
┌─ Máy dữ liệu 10.10.90.149 ─┐
│ MySQL 8.4  :3306           │  ← bài viết, cấu hình
│ NFS /srv/nfs/k8s  :2049    │  ← ảnh, file upload
└────────────────────────────┘
```

## Cấu trúc repo

```
data-server/          Ansible: cài MySQL (Docker Compose) + NFS lên 10.10.90.149
k8s-cicd/             Ansible: cài lên K8s: NFS driver, MetalLB, Traefik, Argo CD, Jenkins
gitops/wordpress/     Helm chart WordPress (Argo CD đọc thư mục này)
  values.yaml           giá trị mặc định
  values-prod.yaml      môi trường production: domain, số pod, image (Jenkins tự sửa image)
  templates/            Deployment, Service, Ingress, PVC (NFS), PodDisruptionBudget
```

Repo thứ hai `Jack-mai/wordpress-app` (code WordPress) chỉ cần cho **Phần B**.

---

## Chuẩn bị

| Việc | Kiểm tra |
|---|---|
| Máy Ansible `10.10.90.140` có Ansible ≥ 2.15 | `ansible --version` |
| SSH key từ `.140` vào được 6 node K8s (đã làm khi dựng cluster) | `ssh administrator@10.10.90.141 hostname` |
| Máy `10.10.90.149` cài Ubuntu 22.04/24.04, user `administrator` có sudo | |
| Dải IP `10.10.90.151–159` còn trống (MetalLB cấp cho Traefik) | lệnh ping bên dưới |
| GitHub token (classic): quyền `repo`, `write:packages`, `read:packages` | GitHub > Settings > Developer settings > Tokens (classic) |

```bash
for i in $(seq 151 159); do ping -c1 -W1 10.10.90.$i >/dev/null && echo "10.10.90.$i ĐANG DÙNG"; done
# không in ra gì = các IP đều trống
```

Nếu user SSH không phải `administrator`, sửa `ansible_user` trong `data-server/inventory/hosts.ini` và `k8s-cicd/inventory/hosts.ini`.

---

# PHẦN A: Cài WordPress lên K8s, dữ liệu ở 10.10.90.149

Xong phần này: WordPress chạy trên K8s với image WordPress chính thức, chưa cần Jenkins.

## A1. Lấy repo về máy Ansible

```bash
cd /installer
git clone https://github.com/Jack-mai/Wordpress.git
cd Wordpress
ansible-galaxy collection install community.general ansible.posix
```

## A2. Cài máy dữ liệu: MySQL + NFS trên 10.10.90.149

```bash
cd /installer/Wordpress/data-server
ssh-copy-id -i ~/.ssh/id_rsa_ansible.pub administrator@10.10.90.149   # nhập mật khẩu 1 lần
ansible dataserver -m ping                       # phải ra "pong"

cp vars/secrets.yml.example vars/secrets.yml
nano vars/secrets.yml                            # đặt mysql_root_password, mysql_wordpress_password
ansible-vault encrypt vars/secrets.yml           # khuyến nghị: mã hóa, sẽ hỏi đặt mật khẩu vault

ansible-playbook site.yml --ask-vault-pass
```

Mất khoảng 3–5 phút. Kết quả mong đợi ở cuối:

- `MySQL chạy tại 10.10.90.149:3306` và `User ứng dụng: wordpress@10.10.90.%`
- `NFS: 10.10.90.149:/srv/nfs/k8s (cho phép: 10.10.90.141, ...)`
- Hai bước `Port MySQL 3306` và `Port NFS 2049` đều `ok`

## A3. Khai báo cho phía K8s

```bash
cd /installer/Wordpress/k8s-cicd
cp vars/secrets.yml.example vars/secrets.yml
nano vars/secrets.yml
ansible-vault encrypt vars/secrets.yml
```

Trong `vars/secrets.yml`:

| Biến | Điền gì |
|---|---|
| `github_token` | Token GitHub (Argo CD dùng để đọc repo Wordpress private) |
| `jenkins_admin_password` | Mật khẩu admin Jenkins (dùng ở Phần B) |
| `wordpress_db_password` | **Giống hệt** `mysql_wordpress_password` ở bước A2 |

Mở `vars/cicd.yml` kiểm tra. Mặc định đã đúng cho hệ thống này:

```yaml
metallb_ip_range: "10.10.90.151-10.10.90.159"
ingress_ip: "10.10.90.151"
github_user: "Jack-mai"
wordpress_db_host: "10.10.90.149"
nfs_server: "10.10.90.149"
nfs_share: "/srv/nfs/k8s"
```

## A4. Cài lên K8s (chưa có Jenkins)

```bash
ansible-playbook cicd.yml --ask-vault-pass --skip-tags jenkins
```

Mất khoảng 10–15 phút. Playbook làm lần lượt:

1. Cài NFS client lên 6 node, cài **csi-driver-nfs**, tạo StorageClass `nfs-csi`, rồi **thử ghi file lên NFS** (bước `Kết quả thử NFS`).
2. Cài **MetalLB** (IP ảo), **Traefik** (Ingress, IP `10.10.90.151`), **metrics-server**.
3. Cài **Argo CD**.
4. Tạo secret `wordpress-db`, **thử đăng nhập MySQL từ trong K8s** (bước `Kết quả kiểm tra DB`).
5. Tạo Argo CD Application `wordpress`: Argo CD đọc Helm chart `gitops/wordpress` và deploy.

Nếu bước thử NFS hoặc thử DB báo lỗi, playbook dừng ở đó kèm thông báo lý do (xem mục **Lỗi hay gặp**).

## A5. Kiểm tra

Trên `k8s-master1`:

```bash
kubectl -n wordpress get pods,pvc,ingress -o wide
# 3 pod wordpress-xxx: 1/1 Running, nằm trên 3 node khác nhau
# pvc wordpress-uploads: Bound, STORAGECLASS nfs-csi
# ingress wordpress: ADDRESS 10.10.90.151
```

Mở trình duyệt: **https://10.10.90.151**, chọn ngôn ngữ, tạo tài khoản admin.

Thử upload một ảnh trong **Media > Add New**, rồi kiểm tra ảnh đã nằm trên máy dữ liệu:

```bash
ssh administrator@10.10.90.149 "ls -R /srv/nfs/k8s/wordpress-wordpress-uploads | head"
```

Argo CD: **https://10.10.90.151/argocd**, đăng nhập `admin` với mật khẩu in ra cuối playbook. App `wordpress` phải ở trạng thái **Synced / Healthy**.

### Truy cập và HTTPS

| Dịch vụ | Địa chỉ |
|---|---|
| WordPress | https://10.10.90.151 |
| Argo CD | https://10.10.90.151/argocd |
| Jenkins (Phần B) | https://10.10.90.151/jenkins |

`http://` tự chuyển sang `https://`. Chứng chỉ do **CA nội bộ** (cert-manager) cấp cho IP `10.10.90.151`, vì CA công cộng không cấp chứng chỉ cho IP nội bộ. Máy chưa tin CA này sẽ thấy cảnh báo "Not secure"; vẫn vào được nhưng nên cài CA để có ổ khóa xanh.

File CA nằm ở `k8s-cicd/internal-ca.crt` trên máy `.140`, sinh ra sau khi chạy playbook. Chép file này về máy tính, rồi:
- **Windows:** nháy đúp file → Install Certificate → Local Machine → Place all certificates in → **Trusted Root Certification Authorities** → Finish. Khởi động lại trình duyệt.
- **macOS:** mở bằng Keychain Access → System → nháy đúp chứng chỉ → Trust → **Always Trust**.
- **Ubuntu:** `sudo cp internal-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`.
- **Firefox** dùng kho chứng chỉ riêng: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import.

---

# PHẦN B: CI/CD hoàn chỉnh

Xong phần này: sửa code (theme, plugin), push lên GitHub, và khoảng 5 phút sau web tự chạy bản mới, không gián đoạn.

```
push code ─► wordpress-app ─► Jenkins: build image ─► GHCR
                                  │
                                  └─► sửa image trong gitops/wordpress/values-prod.yaml (repo Wordpress)
                                                   │
                                                   ▼
                                     Argo CD thấy thay đổi ─► deploy Helm chart (RollingUpdate)
```

## B1. Tạo repo code `wordpress-app`

Trên GitHub tạo repo **`Jack-mai/wordpress-app`** (Private). Trên máy tính, giải nén file `wordpress-app.zip`:

```bash
cd wordpress-app
git init -b main
git add .
git commit -m "init"
git remote add origin https://github.com/Jack-mai/wordpress-app.git
git push -u origin main
```

## B2. Cài Jenkins

Trên máy `.140`:

```bash
cd /installer/Wordpress/k8s-cicd
ansible-playbook cicd.yml --ask-vault-pass --tags jenkins
```

Lần đầu mất 10–20 phút vì Jenkins tải plugin từ Internet. Jenkins được cấu hình sẵn bằng code (JCasC):

- Credential `github` (user + token)
- Job `wordpress-app`: kiểm tra repo mỗi 2 phút, build bằng BuildKit (không cần Docker)

## B3. Theo dõi lần build đầu tiên

1. Mở **https://10.10.90.151/jenkins**, đăng nhập `admin` / `jenkins_admin_password`.
2. Trong vòng 2 phút, job `wordpress-app` tự chạy build #1. Mở job, chọn **Console Output** để xem log.
3. Build xong:
   - GitHub > Jack-mai > **Packages** có `wordpress-app`.
   - Repo **Wordpress** có commit mới `wordpress: deploy <tag> [jenkins]`, sửa `values-prod.yaml`.
4. Trong 1–3 phút, Argo CD deploy image mới. Kiểm tra:

```bash
curl -k https://10.10.90.151/?build-info
# in ra tag vừa build, vd: 1a2b3c4-1
kubectl -n wordpress get deploy wordpress -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## B4. Quy trình hằng ngày

| Muốn | Làm |
|---|---|
| Thêm/sửa theme, plugin | Sửa trong `wordpress-app/wp-content/`, push. Khoảng 5 phút sau lên web. Plugin mới thì vào admin bấm Kích hoạt |
| Đổi số pod, domain, RAM | Sửa `gitops/wordpress/values-prod.yaml` trong repo Wordpress, push. Argo CD áp dụng trong 1–3 phút |
| Quay về bản trước | Repo Wordpress: `git revert <commit "wordpress: deploy ...">` rồi push. Argo CD đưa về image cũ |
| Xem lịch sử deploy | Argo CD > app `wordpress` > History |

> **Lưu ý:** Jenkins tự commit vào repo Wordpress sau mỗi lần build. Trước khi anh sửa gì trong repo Wordpress, luôn chạy `git pull` trước.

---

## Lệnh hữu ích (trên k8s-master1)

```bash
kubectl -n wordpress get pods -o wide
kubectl -n wordpress logs deploy/wordpress -f
kubectl -n argocd get applications
kubectl -n jenkins get pods
kubectl get storageclass
kubectl top nodes
```

Trên máy dữ liệu `.149`:

```bash
cd /opt/mysql && docker compose ps                # MySQL
sudo exportfs -v                                  # NFS
du -sh /srv/nfs/k8s/*                             # dung lượng uploads
ls /opt/mysql/backup /opt/backup/nfs              # backup hằng đêm
```

## Lỗi hay gặp

| Triệu chứng | Nguyên nhân / xử lý |
|---|---|
| `Kết quả thử NFS` báo lỗi | Chưa chạy `data-server`, hoặc IP node không có trong `nfs_allowed_clients` (`data-server/group_vars/all.yml`) |
| `Kết quả kiểm tra DB` báo `Access denied` | `wordpress_db_password` (k8s-cicd) khác `mysql_wordpress_password` (data-server) |
| `Kết quả kiểm tra DB` báo `Can't connect` | MySQL trên `.149` chưa chạy: `docker compose ps` trong `/opt/mysql` |
| Traefik không nhận IP `.151` | IP đang bị máy khác dùng hoặc nằm ngoài `metallb_ip_range` |
| Argo CD báo `repository not found` | Token thiếu quyền `repo`, hoặc sai `gitops_repo_url` |
| Pod WordPress `ImagePullBackOff` sau Phần B | Secret `ghcr-pull` sai token: `ansible-playbook cicd.yml --tags wordpress` |
| Upload ảnh báo không ghi được thư mục | `kubectl -n wordpress logs deploy/wordpress -c fix-uploads-permission` |
| Build lỗi `401 unauthorized` khi push image | Token thiếu `write:packages` |
| Build lỗi ở bước BuildKit (`permission denied`) | `kubectl -n jenkins describe pod <agent>`, gửi log để xử lý |
| WordPress "Error establishing a database connection" | `ansible-playbook cicd.yml --tags wordpress` (kiểm tra lại kết nối DB) |

## Giới hạn hiện tại

- Máy `.149` giữ cả DB lẫn ảnh, là điểm chết duy nhất. Nên bật snapshot VM và chép thư mục backup sang NAS hoặc máy khác.
- Chưa có HTTPS (cần tên miền thật + cert-manager).
- Jenkins lưu dữ liệu trên ổ của một node (local-path). Node đó chết thì Jenkins phải dựng lại (cấu hình và job tự tạo lại từ code).
