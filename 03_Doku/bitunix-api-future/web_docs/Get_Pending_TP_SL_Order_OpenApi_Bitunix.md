---
content_hash: sha256:c679336312fc3d29c48f75ef18b15e9cee06e8b2776aab667cc6355fa40769b4
crawled_at: '2026-05-28T18:54:24.734032+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html
tags:
- bitunix-api-future
- web-docs
title: Get Pending TP/SL Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html#VPContent)
Menu
Return to top
# Get Pending TP/SL Order [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html#get-pending-tp-sl-order)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html#description)
Get Pending TP/SL Order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html#http-request)
  * GET /api/v1/futures/tpsl/get_pending_orders

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | false  | Trading pair  |
| positionId  | string  | false  | position id  |
| side  | int32  | false  | order side  |
| positionMode  | int32  | false  | order position mode  |
| skip  | int64  | false  | skip order count default: 0  |
| limit  | int64  | false  | Number of queries: Maximum: 100, default: 10  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/tpsl/get_pending_orders?symbol=BTCUSDT' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/get_pending_tp_sl_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| id  | string  | order id  |
| positionId  | string  | position id  |
| symbol  | string  | coin pair  |
| base  | string  | base  |
| quote  | string  | quote  |
| tpPrice  | string  | Take-profit trigger price  |
| tpStopType  | string  | Take-profit trigger typeLAST_PRICEMARK_PRICE  |
| slPrice  | string  | Stop-loss trigger price  |
| slStopType  | string  | Stop-loss trigger typeLAST_PRICEMARK_PRICE  |
| tpOrderType  | string  | Take-profit order typeLIMITMARKET Default is market.  |
| tpOrderPrice  | string  | Take-profit order price  |
| slOrderType  | string  | Stop-loss order typeLIMITMARKET Default is market.  |
| slOrderPrice  | string  | Stop-loss order price  |
| tpQty  | string  | Take-profit order quantity(base coin)At least one of `tpQty` or `slQty` is required.  |
| slQty  | string  | Stop-loss order quantity(base coin)At least one of `tpQty` or `slQty` is required.  |
Response Example
json
```
{"code":0,"data":[{"id":"123","positionId":"12345678","symbol":"BTCUSDT","base":"BTC","quote":"USDT","tpPrice":"50000","tpStopType":"LAST_PRICE","slPrice":"70000","slStopType":"LAST_PRICE","tpOrderType":"LIMIT","tpOrderPrice":"50000","slOrderType":"LIMIT","slOrderPrice":"70000","tpQty":"0.01","slQty":"0.01"}],"msg":"Success"}
```