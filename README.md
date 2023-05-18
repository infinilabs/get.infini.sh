# How to use

```bash
#Please ensure that the current operator user has permission to install the directory, such as /opt/console
#initialize the installation directory
sudo mkdir -p /opt/console && sudo chown -R ${USER} /opt/console

#latest version
curl -sSL http://get.infini.sh | bash -s -- -p console -d /opt/console
curl -sSL http://get.infini.sh | bash -s -- -p gateway -d /opt/gateway
curl -sSL http://get.infini.sh | bash -s -- -p loadgen -d /opt/loadgen

#easysearch custom version
curl -sSL http://get.infini.sh | bash -s -- -p easysearch -d /data/easysearch -v 1.0.0
```
