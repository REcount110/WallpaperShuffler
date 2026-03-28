## 壁纸轮换

### v2（支持 100k+ 图片）

```bash
# 直接启动
bash photography_wallpaper_shuffler_v2.sh

# 后台启动
nohup bash photography_wallpaper_shuffler_v2.sh &


v2 核心改进：
- **SQLite DB 计数存储** — 跨重启持久化，文件名保持原始形态，O(1) SQL UPDATE
- **磁盘播放列表** — 10万图片内存占用 ~0（vs v1 ~20MB）
- **修复 should_refresh_list 逻辑反转 bug** — v1 每迭代都全量 find
- **find -maxdepth 20** — 防符号链接循环
- **USR1/HUP 信号** — 动态刷新/热重载配置


## 配置

### v2 配置（热重载）

创建 `~/.wallpaper_shuffle_v2.conf`，然后 `kill -HUP <pid>`：
```
INTERVAL=5
MAX_SHOW=3
LOG_LEVEL=info
```

也可通过环境变量启动时指定：
```bash
INTERVAL=5 MAX_SHOW=5 bash photography_wallpaper_shuffler_v2.sh
```
