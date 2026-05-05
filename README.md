## 壁纸轮换

### v2.3（支持 500k+ JPEG，新增 RAW 过滤）

```bash
# 直接启动
bash photography_wallpaper_shuffler_v2.sh

# 后台启动
nohup bash photography_wallpaper_shuffler_v2.sh &
```

v2.3 核心改进：
- **`cmd_next` O(1)** — 两阶段 SQL（bucket 聚合 + RANDOM() LIMIT 1），Python 内存与图片总量无关
- **流式批量扫描** — `scan` 使用批量 INSERT（默认 5000/批）和临时表做 SQL-side 去活，内存低
- **文件大小过滤** — 新增 `MAX_FILE_SIZE`（bytes）配置，可跳过大文件（例如 RAW）以防 GNOME 解码 OOM
- **SQLite 调优** — 增加 cache_size、temp_store=MEMORY、timeout 调整以支持 500k+ 行
- **保留之前改进** — find 深度限制、USR1/HUP、锁屏短轮询、OOM 自动限流

## 配置

### v2.3 配置（热重载）

创建 `~/.wallpaper_shuffle_v2.conf`，然后 `kill -HUP <pid>`：
```
INTERVAL=5
MAX_SHOW=3
LOG_LEVEL=info
# 跳过 30 MB 以上文件（建议用于混合 RAW 库）
MAX_FILE_SIZE=31457280
```

也可通过环境变量启动时指定：
```bash
INTERVAL=5 MAX_SHOW=5 MAX_FILE_SIZE=31457280 bash photography_wallpaper_shuffler_v2.sh
```
