# data-server

Máy dữ liệu dùng chung cho cụm K8s, chạy trên **một VM Ubuntu `10.10.90.149`**, dựng bằng Ansible:

- **MySQL 8.4** chạy bằng Docker Compose: database cho WordPress và các ứng dụng khác.
- **NFS file share**: ảnh và file upload của WordPress. Pod trên K8s mount qua `csi-driver-nfs` với chế độ ReadWriteMany, nên nhiều pod dùng chung một thư mục.

Project này độc lập với cluster K8s. Bên K8s (`k8s-cicd/vars/cicd.yml`) chỉ cần IP, user và mật khẩu DB, cùng đường dẫn NFS.

## Cấu trúc

```
ansible.cfg
inventory/hosts.ini          # máy dữ liệu (10.10.90.149)
group_vars/all.yml           # MySQL: phiên bản, tuning, database/user (mysql_apps)
                             # NFS: thư mục chia sẻ, IP được phép mount, lịch backup
vars/secrets.yml.example     # mật khẩu root + user từng app
site.yml
roles/mysql_docker/          # Docker, compose MySQL, DB/user, backup mysqldump
roles/nfs_server/            # nfs-kernel-server, /etc/exports, backup file share
```

## Chạy (từ máy Ansible 10.10.90.140)

```bash
cd data-server
ssh-copy-id -i ~/.ssh/id_rsa_ansible.pub administrator@10.10.90.149
ansible dataserver -m ping

cp vars/secrets.yml.example vars/secrets.yml
nano vars/secrets.yml
ansible-vault encrypt vars/secrets.yml           # khuyến nghị

ansible-playbook site.yml --ask-vault-pass       # cài cả MySQL và NFS
ansible-playbook site.yml --ask-vault-pass --tags mysql   # chỉ MySQL
ansible-playbook site.yml --ask-vault-pass --tags nfs     # chỉ NFS
```

Chạy lại bao nhiêu lần cũng được.

## Thông tin cho phía K8s

| | Giá trị | Khai báo bên `k8s-cicd/vars/cicd.yml` |
|---|---|---|
| MySQL | `10.10.90.149:3306`, database/user `wordpress` | `wordpress_db_host`, `wordpress_db_name`, `wordpress_db_user` |
| Mật khẩu DB | `mysql_wordpress_password` | `wordpress_db_password` (secrets.yml, **phải giống**) |
| NFS | `10.10.90.149:/srv/nfs/k8s` | `nfs_server`, `nfs_share` |

Mỗi PVC trên K8s là một thư mục con trên máy này, đặt tên theo `<namespace>-<tên PVC>`. Uploads của WordPress nằm ở `/srv/nfs/k8s/wordpress-wordpress-uploads`.

## Thêm database cho ứng dụng khác

`group_vars/all.yml`:
```yaml
mysql_apps:
  - { name: wordpress, user: wordpress, password_var: mysql_wordpress_password, allowed_host: "10.10.90.%" }
  - { name: shop,      user: shop,      password_var: mysql_shop_password,      allowed_host: "10.10.90.%" }
```
Thêm `mysql_shop_password: "..."` vào `vars/secrets.yml`, rồi chạy lại `--tags mysql`.

## Vận hành

| Việc | Lệnh (trên 10.10.90.149) |
|---|---|
| Trạng thái MySQL | `cd /opt/mysql && docker compose ps` |
| Log MySQL | `docker compose logs -f` |
| Vào MySQL bằng root | `docker exec -it mysql mysql -uroot -p` |
| Restore MySQL | `gunzip -c /opt/mysql/backup/all-databases-XXXX.sql.gz \| docker exec -i mysql mysql -uroot -p<mat-khau>` |
| Xem thư mục đang chia sẻ | `sudo exportfs -v` |
| Xem node nào đang mount | `sudo ss -tn state established '( sport = :2049 )'` |
| Dung lượng uploads | `du -sh /srv/nfs/k8s/*` |
| Restore file share | `tar -C /srv/nfs/k8s -xzf /opt/backup/nfs/nfs-XXXX.tar.gz` |

| Backup | Lúc | Giữ | Nơi lưu |
|---|---|---|---|
| MySQL (mysqldump) | 01:30 hằng ngày | 7 ngày | `/opt/mysql/backup` |
| File share (tar.gz) | 02:00 hằng ngày | 7 ngày | `/opt/backup/nfs` |

## Lưu ý

- **Máy này là điểm chết duy nhất**: máy hỏng thì WordPress mất cả DB lẫn ảnh. Cần đặt VM này trên storage tốt, có snapshot VM định kỳ (vSphere/Proxmox), và **chép backup sang NAS hoặc máy khác**. Hiện backup vẫn nằm trên chính máy này.
- Ổ đĩa: tách `/srv/nfs` và `/opt` ra ổ riêng nếu có thể, để upload tăng đột biến không làm đầy ổ hệ điều hành và làm MySQL ngừng.
- Docker mở port bằng iptables nên UFW không chặn được port 3306. Việc giới hạn truy cập dựa vào cấu hình user MySQL (`allowed_host`) và danh sách IP trong `/etc/exports`.
- Thêm node K8s mới thì thêm IP của node đó vào `nfs_allowed_clients` rồi chạy lại `--tags nfs`.
