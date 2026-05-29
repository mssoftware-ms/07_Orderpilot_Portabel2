---
content_hash: sha256:b0756aa7fa445d3e9fbacd69ac66f9ac81adbafe94952abf991b70f524e700fb
crawled_at: '2026-05-28T18:54:24.726046+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html
tags:
- bitunix-api-future
- web-docs
title: Get History Trades | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html#VPContent)
Menu
Return to top
# Get History Trades [​](https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html#get-history-trades)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html#description)
get history trades, sort by create time desc
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html#http-request)
  * GET /api/v1/futures/trade/get_history_trades

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | false  | Trading pair  |
| orderId  | string  | false  | order id  |
| positionId  | string  | false  | position id  |
| startTime  | int64  | false  | Start timestampUnix timestamp in milliseconds format, e.g. 1597026383085  |
| endTime  | int64  | false  | Start timestampUnix timestamp in milliseconds format, e.g. 1597026683085  |
| skip  | int64  | false  | skip order count default: 0  |
| limit  | int64  | false  | Number of queries: Maximum: 100, default: 10  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/get_history_trades?symbol=BTCUSDT' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/get_history_trades.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| tradeList  | list  | trade list  |
| >tradeId  | string  | trade id  |
| >orderId  | string  | order id  |
| >symbol  | string  | Trading pair  |
| >qty  | string  | Amount (base coin)  |
| >positionMode  | string  | ONE_WAY or HEDGE  |
| >marginMode  | string  | ISOLATION or CROSS  |
| >leverage  | int  | leverage  |
| >price  | string  | Price of the order.Required if the order type is **LIMIT**  |
| >side  | string  | Order directionbuy: **BUY** sell: **SELL**  |
| >orderType  | string  | Order type**LIMIT** : limit orders**MARKET** : market orders  |
| >effect  | string  | Order expiration date.Required if the orderType is limit**IOC** : Immediate or cancel**FOK** : Fill or kill**GTC** : Good till canceled(default value)**POST_ONLY** : POST only  |
| >clientId  | string  | Customize order ID  |
| >reduceOnly  | boolean  | Whether or not to just reduce the position  |
| >fee  | string  | fee  |
| >realizedPNL  | string  | realized pnl  |
| >ctime  | int64  | create timestamp  |
| >roleType  | string  | Trader tag **TAKER** : maker**MAKER** : maker  |
| total  | int64  | total count  |
Response Example
json
```
{"code":0,"data":{"tradeList":[{"tradeId":"123","orderId":"11111","qty":"1","price":"60000","symbol":"BTCUSDT","positionMode":"HEDGE","marginMode":"ISOLATION","leverage":15,"fee":"0.01","realizedPNL":"1.78","type":"LIMIT","effect":"GTC","reduceOnly":false,"clientId":"22222","source":"api","ctime":1597026383085,"roleType":"TAKER"}],"total":10},"msg":"Success"}
```