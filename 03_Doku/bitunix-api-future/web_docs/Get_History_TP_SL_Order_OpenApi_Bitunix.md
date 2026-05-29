---
content_hash: sha256:31253a58fca5bd60d79fd93d901a0309deea9e9a2629b004e3f4a5ca5b7863b3
crawled_at: '2026-05-28T18:54:24.700094+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html
tags:
- bitunix-api-future
- web-docs
title: Get History TP/SL Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html#VPContent)
Menu
Return to top
# Get History TP/SL Order [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html#get-history-tp-sl-order)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html#description)
Get History TP/SL Order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html#http-request)
  * GET /api/v1/futures/tpsl/get_history_orders

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | false  | Trading pair  |
| side  | int32  | false  | order side  |
| positionMode  | int32  | false  | order position mode  |
| startTime  | int64  | false  | Start timestampUnix timestamp in milliseconds format, e.g. 1597026383085  |
| endTime  | int64  | false  | Start timestampUnix timestamp in milliseconds format, e.g. 1597026683085  |
| skip  | int64  | false  | skip order count default: 0  |
| limit  | int64  | false  | Number of queries: Maximum: 100, default: 10  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/tpsl/get_history_orders?symbol=BTCUSDT' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_history_tp_sl_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderList  | list  | TP/SL order List  |
| >id  | string  | order id  |
| >positionId  | string  | position id  |
| >symbol  | string  | coin pair  |
| >base  | string  | base  |
| >quote  | string  | quote  |
| >tpPrice  | string  | Take-profit trigger price  |
| >tpStopType  | string  | Take-profit trigger typeLAST_PRICEMARK_PRICE  |
| >slPrice  | string  | Stop-loss trigger price  |
| >slStopType  | string  | Stop-loss trigger typeLAST_PRICEMARK_PRICE  |
| >tpOrderType  | string  | Take-profit order typeLIMITMARKET Default is market.  |
| >tpOrderPrice  | string  | Take-profit order price  |
| >slOrderType  | string  | Stop-loss order typeLIMITMARKET Default is market.  |
| >slOrderPrice  | string  | Stop-loss order price  |
| >tpQty  | string  | Take-profit order quantity(base coin)At least one of `tpQty` or `slQty` is required.  |
| >slQty  | string  | Stop-loss order quantity(base coin)At least one of `tpQty` or `slQty` is required.  |
| >status  | string  | TP/SL order status  |
| >ctime  | int64  | create timestamp  |
| >triggerTime  | int64  | trigger time timestamp  |
| total  | int64  | total  |
Response Example
json
```
{"code":0,"data":[{"positionId":"12345678","symbol":"BTCUSDT","qty":"0.5","entryValue":"30000","side":"LONG","positionMode":"HEDGE","marginMode":"ISOLATION","leverage":100,"fee":"0.1","funding":"-0.2","realizedPNL":"102.9","margin":"300","unrealizedPNL":"1.5","liqPrice":"22209","marginRate":"0.01","ctime":1691382137448,"mtime":1691382137448}],"msg":"Success"}
```