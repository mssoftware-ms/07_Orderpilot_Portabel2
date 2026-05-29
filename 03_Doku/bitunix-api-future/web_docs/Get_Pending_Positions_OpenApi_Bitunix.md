---
content_hash: sha256:b558c1886328194219188e30985e6c612a27eb9bfb4574e5aa7ab267a26d5f07
crawled_at: '2026-05-28T18:54:24.684293+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html
tags:
- bitunix-api-future
- web-docs
title: Get Pending Positions | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html#VPContent)
Menu
Return to top
# Get Pending Positions [​](https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html#get-pending-positions)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html#description)
Get Pending Positions
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html#http-request)
  * GET /api/v1/futures/position/get_pending_positions

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | false  | Trading pair  |
| positionId  | string  | false  | position id  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/position/get_pending_positions?symbol=BTCUSDT' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| positionId  | string  | position id  |
| symbol  | string  | Trading pair  |
| qty  | string  | position amount  |
| entryValue  | string  | Available amount for positions  |
| side  | string  |  **LONG** **SHORT**  |
| marginMode  | string  |  **ISOLATION** **CROSS**  |
| positionMode  | string  |  **ONE_WAY** **HEDGE**  |
| leverage  | int32  | leverage  |
| fee  | string  | Deducted transaction fees: transaction fees deducted during the position  |
| funding  | string  | total funding fee during the position  |
| realizedPNL  | string  | Realized PnL(exclude funding fee and transaction fee)  |
| margin  | string  | locked asset of the position  |
| unrealizedPNL  | string  | Unrealized PnL  |
| liqPrice  | string  | Estimated liquidation priceIf the value <= 0, it means the position is at low risk and there is no liquidation price at this time  |
| marginRate  | string  | Margin ratio  |
| avgOpenPrice  | string  | Average open price  |
| ctime  | int64  | create timestamp  |
| mtime  | int64  | latest modify timestamp  |
Response Example
json
```
{"code":0,"data":[{"positionId":"12345678","symbol":"BTCUSDT","qty":"0.5","entryValue":"30000","side":"LONG","positionMode":"HEDGE","marginMode":"ISOLATION","leverage":100,"fee":"0.1","funding":"-0.2","realizedPNL":"102.9","margin":"300","unrealizedPNL":"1.5","liqPrice":"22209","marginRate":"0.01", "avgOpenPrice": "1.0","ctime":1691382137448,"mtime":1691382137448}],"msg":"Success"}
```