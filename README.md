# How to use

```bash
#please make sure current operator user have permissionn for install directory, e.g /opt/console
#also you can initialize the install dir before directory. 
sudo mkdir -p /opt/console && sudo chown -R ${USER} /opt/console

#latest version
curl -sSL http://get.infini.sh | bash -s -- -p console -d /opt/console
curl -sSL http://get.infini.sh | bash -s -- -p gateway -d /opt/gateway
curl -sSL http://get.infini.sh | bash -s -- -p loadgen -d /opt/loadgen

#easysearch custom version
curl -sSL http://get.infini.sh | bash -s -- -p easysearch -d /data/easysearch -v 1.0.0
```
