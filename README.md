# Shadowsocks-Auto

## 使用方法

### 下载并执行
```
curl -sS -O https://raw.githubusercontent.com/yuju520/Shadowsocks-Auto/main/Shadowsocks-Auto.sh && chmod +x Shadowsocks-Auto.sh && ./Shadowsocks-Auto.sh
```
或
```
wget -q https://raw.githubusercontent.com/yuju520/Shadowsocks-Auto/main/Shadowsocks-Auto.sh && chmod +x Shadowsocks-Auto.sh && ./Shadowsocks-Auto.sh
```

### Tips
1.脚本执行后会自动检测Shadowsocks的版本，如需下载或更新，则从大佬的仓库拉取已经编译好的文件并进行更新。
2.脚本运行后，会提示输入自定义端口、加密方法、节点名称等信息。（当然可以像我一样偷懒地全部回车）
3.完成后会自动输出Shadowsocks的服务状态以及ss://结构的节点信息

### 卸载
停止 Shadowsocks 服务：
```
sudo systemctl stop shadowsocks
```

禁用 Shadowsocks 服务自启动：
```
sudo systemctl disable shadowsocks
```

删除 Shadowsocks 服务文件并重新加载 systemd 配置：
```
sudo rm /etc/systemd/system/shadowsocks.service
sudo systemctl daemon-reload
```

删除 Shadowsocks 相关配置文件及目录和可执行文件：
```
sudo rm -rf /etc/shadowsocks
sudo rm /usr/local/bin/ssserver
sudo rm /usr/local/bin/sslocal
sudo rm /usr/local/bin/ssurl
sudo rm /usr/local/bin/ssmanager
```
