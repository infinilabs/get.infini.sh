# How to use

```bash
#Please ensure that the current operator user has permission to install the directory
#initialize the installation directory
sudo mkdir -p /opt/console && sudo chown -R ${USER} /opt/console

#install console latest version
curl -sSL http://get.infini.sh | bash -s -- -p console

#install gateway latest version and specify installation directory
curl -sSL http://get.infini.sh | bash -s -- -p gateway -d /opt/gateway

#install loadgen latest version and specify installation directory
curl -sSL http://get.infini.sh | bash -s -- -p loadgen -d /opt/loadgen

#easysearch specify installation directory and version
curl -sSL http://get.infini.sh | bash -s -- -p easysearch -d /data/easysearch -v 1.0.0
```
