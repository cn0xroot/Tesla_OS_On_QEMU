# Tesla rootfs 二进制联网地址与服务器清单

- 来源:`rootfs_2026.squashfs`(解出 `usr/tesla`、`usr/bin`、`usr/sbin`、`usr/lib`、`bin`、`sbin`、`etc`、`opt/odin`、`var/etc`;`lib/modules`、`usr/share` 等未扫)
- 方法:对 ELF 文件做静态字符串提取(URL + 域名)。**只能说明二进制里写了该地址,不能证明运行时一定连接。**
- 路径均为 rootfs 内部绝对路径;`%1` 等为运行时替换的占位符。

---

## 1. 地图与导航(按区域)

### 1.1 百度(中国)

| 接口 | 用途 | 所在二进制 |
|---|---|---|
| `api.map.baidu.com/direction/v2/driving` | 驾车路径规划 | `QtCarTMServer` |
| `api.map.baidu.com/reverse_geocoding/v3/` | 逆地理编码 | `QtCarTMServer` |
| `api.map.baidu.com/api_lamp_service/v1/dynamic_lamp_search` | 红绿灯 | `QtCarTMServer` |
| `api.map.baidu.com/place/v2/{search,detail,suggestion}`、`place/v3/around` | POI 搜索 | `libQtCarGUI.so.1.0.0` |
| `api.map.baidu.com/traffic/TrafficTileService`、`?qt=maprinfo` | 路况瓦片 | `libQtCarMapsCore.so.1.0.0` |
| `mapapip0.bdimg.com/tile/?qt=vtile` | 矢量瓦片 | `libQtCarMapsCore.so.1.0.0` |
| `mapapisp0.bdimg.com/starpic/?qt=satepc` | 卫星图 | `libQtCarMapsCore.so.1.0.0` |
| `intelligentmap-api.baidu.com:443` | 智能地图(用途未查) | `autopilot-api` |


### 1.2 腾讯地图(中国)

| 接口 | 所在二进制 |
|---|---|
| `apis.map.qq.com/ws/direction/v1/driving`、`ws/geocoder/v1/` | `QtCarTMServer` |
| `apis.map.qq.com/ws/place/v1/{search,suggestion}` | `libQtCarGUI.so.1.0.0` |
| `m0/p0/rt0.map.gtimg.com`(矢量、卫星、路况瓦片)、`rtt2.map.qq.com/rtt` | `libQtCarMapsCore.so.1.0.0` |

### 1.3 Google

| 接口 | 所在二进制 |
|---|---|
| `maps.googleapis.com/maps/api/{directions,geocode}/json` | `QtCarTMServer` |
| `maps.googleapis.com/maps/api/elevation/json` | `QtCarTMServer`、`libQtCarGUI.so.1.0.0` |
| `maps.googleapis.com/maps/api/timezone/json` | `QtCarServer`、`QtCarBluetooth` |
| `maps.googleapis.com/maps/api/place/*`、`places.googleapis.com/v1/places*` | `libQtCarGUI.so.1.0.0` |
| `tile.googleapis.com/v1/vectortiles/{featuretiles,traffictiles}`、`www.googleapis.com/tile/v1/*` | `libQtCarMapsCore.so.1.0.0` |

### 1.4 T map(韩国)

| 接口 | 所在二进制 |
|---|---|
| `api-tsl.tmap.co.kr/tmap/routes`、`tmap/geo/reversegeocoding` | `QtCarTMServer` |
| `api-tsl.tmap.co.kr/tmap/pois`、`TmapAutoCompleteServer/suggest` | `libQtCarGUI.so.1.0.0` |
| `map-tsl` / `aerial-tsl` / `rtti-tsl.tmap.co.kr` | `libQtCarMapsCore.so.1.0.0` |

### 1.5 Tesla 自建

| 地址 | 所在二进制 |
|---|---|
| `maps-%1.go.tesla.services`、`maps-eu-%1`、`maps-ap-%1`、`maps-kr-%1`、`navsrv.eng.go.tesla.services` | `QtCarTMServer` |
| `nav-%1-maps.tesla.cn`(中国) | `QtCarTMServer` |
| `http://localhost:8002/route`、`/trace_route`(本机 Valhalla) | `QtCarTMServer` |
| `http://ape:8888/user_metadata?publisher=maps_poi` | `libQtCarGUI.so.1.0.0` |

`QtCarTMServer` 里还有 `TMQQMapTask`、`TMSktMapTask`、`TMOllehMapTask` 等路由任务类。区域判定符号包括 `VehicleUtils::navigationMapRegion`、`forcedMapRegion`、`NavUtils::expectedMapRegionForUseCountry`。具体切换条件未逆向,以上为推断。

---

## 2. 语音

| 地址 | 所在二进制 |
|---|---|
| `tts.baidu.com`、`openapi.baidu.com/oauth/2.0/token`、`upl.baidu.com/offline/auth` | `libBDSpeechSDK.so`(百度语音 SDK) |
| 本地模型 `/opt/baidu/models/text_to_speech/DuXiaowen/` | `tesla-tts-service` 使用 |

`/opt/baidu` 内容:`DuXiaowen_speech.dat`(5,743,765 B)、`DuXiaowen_text.dat`(7,433,335 B)、`tts_license.dat`(513 B)。

---

## 3. Tesla 云端

### 3.1 teslamotors.com

| 主机 | 二进制 |
|---|---|
| `firmware.vn.teslamotors.com` | `iris-install`、`updater-envoy`、`libQtCarUtils.so.1.0.0` |
| `firmware-media.vn.teslamotors.com` | `libQtCarGUI.so.1.0.0` |
| `mothership.vn.teslamotors.com` | `tesla-tts-service`、`tesla-arcade-daemon`、`libNVH.so.1.0.0` 等(8 个) |
| `stash.teslamotors.com` | `canlogs`、`iris-install`、`updater-envoy` 等(6 个) |

### 3.2 tesla.services

| 主机 | 二进制 |
|---|---|
| `telemetry-{eng,prd}.vn.tesla.services`、`logupload-{eng,prod}.vn.tesla.services`、`managed-charging.sn.tesla.services` | `QtCarServer` |
| `daws.tesla.services`、`daws-kr.go.tesla.services` | `QtCarGpsManager` |
| `x1.ap.tesla.services` | `libSketchPad2.so.1.0.0` |
| `api-{eng,prd}.ap`、`hermes-{eng,prd}.ap`、`telemetry-{eng,prd}.ap`、`s3.ap`、`apmv3.go.tesla.services` | `autopilot-api` |

### 3.3 tesla.com

| 主机 | 二进制 |
|---|---|
| `auth.tesla.com` | `QtCarServer` |
| `darkfield.tesla.com` | `QtCarConnMan` |
| `hservice` / `service` / `parts` / `www.tesla.com`、`akamai-apigateway-ownership-mobile-app-stage.tesla.com` | `libQtCarGUI.so.1.0.0` |
| `apf-api.{prd,eng}.vn.cloud.tesla.com`、`x3-{eng,static,prod}.obs.tesla.com` | `autopilot-api` |
| `github-fw.tesla.com` | `authd`、`car-assist`、`command-router`、`webrtc-comms`、`vaultd` 等(夹在 protobuf 字符串里,是否真实主机未确认) |

### 3.4 tesla.cn(中国)

| 主机 | 二进制 / 文件 |
|---|---|
| `apm.tesla.cn` | `QtCarGpsManager` |
| `cloud.tesla.cn`、`*.vn.cloud.tesla.cn` | `QtCarServer` |
| `www.tesla.cn` | `libQtCarGUI.so.1.0.0` |
| `tesla.cn` | `QtCarConnMan`、`tesla-chromium-*` |
| `api-ap-{eng,prd}.vn.cloud.tesla.cn`、`hermes-ap-*`、`hermes-x2-api.*`、`apf-api.*.vn.cloud.tesla.cn`、`apigateway-x2-trigger.tesla.cn` | `autopilot-api` |
| `connman.vn.cloud.tesla.cn/online/status.html` | `/etc/connman/main-cn.conf` |
| `HERMES_ENV.vn.cloud.tesla.cn` | `/etc/hermes-urls.vars` |
| `assistant-api.{eng,prd}.cnn1.vn.cloud.tesla.cn` | `/etc/car-assist.vars` |
| `cx.tesla.cn/video-tutorial` | `/usr/tesla/UI/assets/games.json` |

### 3.5 AWS 中国(`autopilot-api`)

- `tesla-hermes-clips-cn.s3.cn-north-1.amazonaws.com.cn`
- `protocolfirehose.cn-north-1.amazonaws.com.cn`

---

## 4. 其他第三方

| 地址 | 二进制 |
|---|---|
| `api.spotify.com/v1`、`i.scdn.co/image` | `libQtCarMediaV2.so.1.0.0` |
| `api.sandbox.cnrd.io` | `QtCarRadioServer` |
| `tesla-chromium-*` 内置搜索引擎表:`www.baidu.com`、`suggestion.baidu.com`、`google.com.cn`、`ac.search.naver.com`、`qq.com`、`yahoo.com.cn` 等 | Chromium 默认数据,不代表主动连接 |

## 5. 已排除的噪声

`github.com`、`golang.org`、`freedesktop.org`、`w3.org`、`gnu.org`、各 CA 域名(comodo、godaddy、entrust 等)、`crbug.com`、`example.com` 等,来自开源库的版权声明、文档链接和证书信息,不是服务连接。

