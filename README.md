# Triển khai CI/CD WordPress trên K8s (Jenkins + GHCR + Argo CD)

## Luồng hoạt động

```
Dev push code ──► GitHub: wordpress-app
                       │  (Jenkins poll 2 phút/lần)
                       ▼
                 Jenkins (pod trên K8s)
                   1. BuildKit build image
                   2. push ghcr.io/jack-mai/wordpress-app:<sha>-<build>
                   3. sửa newTag + push ──► GitHub: k8s-gitops
                                                  │  (Argo CD kiểm tra 1 phút/lần)
                                                  ▼
                                            Argo CD (trên K8s)
                                                  │  kubectl apply
                                                  ▼
                                       namespace wordpress: WordPress (3 pod) ──► MySQL 10.10.90.149:3306
                                                                  └──► NFS   10.10.90.149:/srv/nfs/k8s
                                                                  (máy dữ liệu, project riêng: data-server)

Người dùng ──► http://*.10.10.90.151.nip.io ──► MetalLB IP 10.10.90.151 ──► Traefik ──► Service
```

| Thành phần | Vai trò |
|---|---|
| local-path-provisioner | StorageClass mặc định, tạo ổ đĩa (PVC) cho Jenkins |
| csi-driver-nfs | StorageClass `nfs-csi`: uploads WordPress trên NFS của máy dữ liệu, nhiều pod dùng chung (ReadWriteMany) |
| MetalLB | Cấp IP thật (10.10.90.151–159) cho Service type LoadBalancer |
| Traefik | Ingress controller: 1 IP, phân luồng theo tên miền (ingress-nginx đã ngừng phát triển từ 3/2026) |
| metrics-server | `kubectl top`, autoscale |
| Argo CD | CD theo mô hình GitOps |
| Jenkins | CI, build bằng BuildKit rootless (Kaniko đã bị archive) |

## Database và file share

WordPress dùng MySQL và NFS **ngoài K8s**, cùng nằm trên một VM Ubuntu `10.10.90.149`, dựng bằng project riêng **`data-server`** (xem README trong đó). Hai project độc lập, chỉ nối bằng thông tin kết nối:

| `data-server` (máy dữ liệu) | `k8s-cicd` (CI/CD WordPress) |
|---|---|
| máy `10.10.90.149` trong `inventory/hosts.ini` | `wordpress_db_host`, `nfs_server` = `10.10.90.149` trong `vars/cicd.yml` |
| `mysql_apps`: database `wordpress`, user `wordpress` | `wordpress_db_name`, `wordpress_db_user` |
| `mysql_wordpress_password` trong `vars/secrets.yml` | `wordpress_db_password` trong `vars/secrets.yml` (**phải giống**) |
| `nfs_export_dir: /srv/nfs/k8s` | `nfs_share: /srv/nfs/k8s` |
| `nfs_allowed_clients`: IP 6 node K8s | (node mới phải được thêm vào đây) |

Thông tin DB nằm trong secret `wordpress-db` trên K8s, không nằm trong Git. Đổi DB thì sửa biến rồi chạy `ansible-playbook cicd.yml --tags wordpress`.

Uploads: PVC `wordpress-uploads` dùng StorageClass `nfs-csi` (ReadWriteMany, **Retain**: xóa PVC không xóa ảnh). Trên máy dữ liệu, thư mục này là `/srv/nfs/k8s/wordpress-wordpress-uploads`.

## Bước 1. Tạo 2 repo trên GitHub

Tạo 2 repo **mới**, có thể để private:

- `Jack-mai/wordpress-app`: push nội dung thư mục `wordpress-app/`
- `Jack-mai/k8s-gitops`: push nội dung thư mục `k8s-gitops/`

```bash
cd wordpress-app
git init -b main && git add . && git commit -m "init"
git remote add origin https://github.com/Jack-mai/wordpress-app.git
git push -u origin main
# làm tương tự với k8s-gitops
```

> Phải tách 2 repo: Jenkins push vào `k8s-gitops`. Nếu dùng chung một repo, mỗi lần Jenkins push sẽ lại kích hoạt build mới và tạo vòng lặp.

## Bước 2. Tạo GitHub Token

GitHub > Settings > Developer settings > Personal access tokens > **Tokens (classic)** > Generate.
Tick các quyền: `repo`, `write:packages`, `read:packages`.

## Bước 3. Đưa thư mục `cicd/` lên máy 10.10.90.140

Thư mục này độc lập, không đụng tới `k8s-ansible` đang chạy cluster:

```
Installer/
├── k8s-ansible/        (cũ, giữ nguyên)
└── cicd/               (mới)
    ├── data-server/    project 1: MySQL + NFS trên 10.10.90.149
    ├── k8s-cicd/       project 2: CI/CD trên K8s (Jenkins, Argo CD, Traefik...)
    └── README.md       file này
```

Push thư mục `cicd/` lên GitHub, rồi trên máy `.140` chạy `git pull`.

Điền mật khẩu cho cả hai project. `vars/secrets.yml` đã có trong `.gitignore`, sẽ không bị đưa lên GitHub:

```bash
cd /installer/Installer/cicd/data-server
cp vars/secrets.yml.example vars/secrets.yml && nano vars/secrets.yml

cd /installer/Installer/cicd/k8s-cicd
cp vars/secrets.yml.example vars/secrets.yml && nano vars/secrets.yml   # token GitHub, mật khẩu Jenkins, mật khẩu DB
```

Kiểm tra `k8s-cicd/vars/cicd.yml`:

- `metallb_ip_range: 10.10.90.151-10.10.90.159`: **9 IP này phải còn trống**.
- `github_user: Jack-mai`
- `wordpress_db_host`, `nfs_server`: `10.10.90.149`

Kiểm tra `ansible_user` trong `inventory/hosts.ini` của cả hai project (mặc định `administrator`).

## Bước 4. Dựng máy dữ liệu: MySQL + NFS (project data-server)

```bash
cd /installer/Installer/cicd/data-server
ssh-copy-id administrator@10.10.90.149
cp vars/secrets.yml.example vars/secrets.yml && nano vars/secrets.yml
ansible-playbook site.yml --ask-vault-pass
```

Các bước chi tiết xem trong `data-server/README.md`.

## Bước 5. Cài CI/CD

```bash
cd /installer/Installer/cicd/k8s-cicd
ansible-playbook cicd.yml --ask-vault-pass    # bỏ --ask-vault-pass nếu không mã hóa
```

Trong lúc chạy, playbook tự kiểm tra hai việc. Nếu một trong hai không đạt, playbook dừng và báo lỗi ngay ở bước đó:

- Cài NFS client lên 6 node, cài csi-driver-nfs, rồi chạy một pod thử **ghi file lên NFS**.
- Trước khi deploy WordPress, chạy một pod thử **đăng nhập MySQL**.

Mất khoảng 15–25 phút, phần lớn thời gian là Jenkins tải plugin. Cuối output có link và mật khẩu.

## Bước 6. Kiểm tra

Mở trên trình duyệt (máy cần truy cập được Internet để phân giải tên miền nip.io):

| | URL | Đăng nhập |
|---|---|---|
| Jenkins | http://jenkins.10.10.90.151.nip.io | admin / `jenkins_admin_password` |
| Argo CD | http://argocd.10.10.90.151.nip.io | admin / in ra cuối playbook |
| WordPress | http://wordpress.10.10.90.151.nip.io | tự tạo ở trang cài đặt |

1. Jenkins: job `wordpress-app` tự chạy build đầu tiên trong vòng 2 phút.
2. Build xong thì repo `k8s-gitops` có commit mới `wordpress: deploy ...`.
3. Argo CD: app `wordpress` chuyển sang **Synced / Healthy**.
4. Mở WordPress và làm trang cài đặt (chọn ngôn ngữ, tạo admin).

Trước build đầu tiên, pod WordPress báo `ImagePullBackOff` vì image chưa có. Điều này bình thường, pod sẽ tự chạy khi build xong.

## Bước 7. Thử CI/CD

Sửa một file trong `wordpress-app`, ví dụ thêm theme, rồi push. Khoảng 3–5 phút sau:

```bash
curl http://wordpress.10.10.90.151.nip.io/?build-info    # in ra tag mới
```

## Lệnh hữu ích (trên master1)

```bash
kubectl get pods -A
kubectl -n wordpress get pods,pvc,ingress
kubectl -n jenkins logs -f statefulset/jenkins -c jenkins
kubectl -n argocd get applications
kubectl top nodes
```

## Không có Internet / không dùng nip.io

Thêm vào file hosts của máy anh (Windows: `C:\Windows\System32\drivers\etc\hosts`):

```
10.10.90.151 jenkins.10.10.90.151.nip.io argocd.10.10.90.151.nip.io wordpress.10.10.90.151.nip.io
```

Nếu có DNS nội bộ, đổi `base_domain` trong `vars/cicd.yml` và host trong `k8s-gitops/apps/wordpress/ingress.yaml`, rồi trỏ `*.<domain>` về `10.10.90.151`.

## Lỗi hay gặp

| Triệu chứng | Xử lý |
|---|---|
| Traefik không nhận IP .151 | IP đang bị máy khác dùng hoặc nằm ngoài `metallb_ip_range` |
| Build lỗi `401 unauthorized` khi push | Token thiếu quyền `write:packages` |
| Pod WordPress `ImagePullBackOff` sau khi đã build | Secret `ghcr-pull` sai token. Chạy lại `ansible-playbook cicd.yml --tags wordpress` |
| Build lỗi ở bước BuildKit (`permission denied`, `mount`) | `kubectl -n jenkins describe pod <agent>` để xem AppArmor/seccomp, rồi gửi log cho em |
| Argo CD báo `repository not found` | Sai `gitops_repo_url` hoặc token không có quyền `repo` |
| WordPress báo "Error establishing a database connection" | Chạy `ansible-playbook cicd.yml --tags wordpress` (có bước kiểm tra kết nối DB); kiểm tra mật khẩu 2 project giống nhau; xem `docker logs mysql` trên máy .149 |
| PVC `wordpress-uploads` kẹt ở `Pending` | `kubectl -n wordpress describe pvc wordpress-uploads`; kiểm tra `exportfs -v` trên máy .149 có IP của node |
| Upload ảnh báo "không thể ghi thư mục" | Xem log initContainer: `kubectl -n wordpress logs deploy/wordpress -c fix-uploads-permission` |
| Đổi token GitHub | Sửa `vars/secrets.yml` rồi chạy `ansible-playbook cicd.yml --tags jenkins,argocd,wordpress` |

## Giới hạn hiện tại (nâng cấp sau)

- **Storage local-path cho Jenkins**: dữ liệu Jenkins nằm trên ổ của một node; node đó chết thì Jenkins không chuyển đi được (job vẫn tạo lại được từ JCasC). Có thể chuyển Jenkins sang `nfs-csi` hoặc Longhorn.
- **Chưa có HTTPS**: có thể thêm cert-manager (Let's Encrypt cần domain thật public, hoặc dùng CA nội bộ).
- **Poll thay vì webhook**: Jenkins ở mạng nội bộ nên GitHub không gọi vào được. Nếu public Jenkins thì đổi sang webhook.
- **Backup**: MySQL (01:30) và file share (02:00) được backup hằng đêm ngay trên máy .149. Nên chép thêm sang máy hoặc NAS khác.
- **Máy dữ liệu chạy 1 máy**: máy .149 chết thì WordPress ngừng (mất cả DB lẫn ảnh). Nên bật snapshot VM định kỳ; cần HA thì thêm MySQL replica và NFS dự phòng.
