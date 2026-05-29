---
content_hash: sha256:f32bb5a23bc9401643b246c35dfbde5b3d3ad44547a168201a16a87cbe6fc7c6
crawled_at: '2026-05-28T18:54:24.823982+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html
tags:
- bitunix-api-future
- web-docs
title: Modify TP/SL Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html#VPContent)
Menu
Return to top
# Modify TP/SL Order [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html#modify-tp-sl-order)
Rate Limit: 10 req/sec/UID
### Description [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html#description)
Modify TP/SL Order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html#http-request)
  * POST /api/v1/futures/tpsl/modify_order

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| orderId  | string  | true  | TP/SL Order ID  |
| tpPrice  | string  | false  | Take-profit trigger priceAt least one of `tpPrice` or `slPrice` is required.  |
| tpStopType  | string  | false  | Take-profit trigger typeLAST_PRICEMARK_PRICE Default is market price.  |
| slPrice  | string  | false  | Stop-loss trigger priceAt least one of `tpPrice` or `slPrice` is required.  |
| slStopType  | string  | false  | Stop-loss trigger typeLAST_PRICEMARK_PRICE Default is market price.  |
| tpOrderType  | string  | false  | Take-profit order typeLIMITMARKET Default is market.  |
| tpOrderPrice  | string  | false  | Take-profit order price  |
| slOrderType  | string  | false  | Stop-loss order typeLIMITMARKET Default is market.  |
| slOrderPrice  | string  | false  | Stop-loss order price  |
| tpQty  | string  | false  | Take-profit order quantity(base coin)At least one of `tpQty` or `slQty` is required.  |
| slQty  | string  | false  | Stop-loss order quantity(base coin)At least one of `tpQty` or `slQty` is required.  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/tpsl/modify_order' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"orderId":"123","tpPrice":"12","tpStopType":"LAST_PRICE","slPrice":"9","slStopType":"LAST_PRICE","tpOrderType":"LIMIT","tpOrderPrice":"11","slOrderType":"LIMIT","slOrderPrice":"8","tpQty":"1","slQty":"1"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_tp_sl_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderId  | string  | TP/SL Order ID  |
Response Example
json
```
{"code":0,"data":{"orderId":"11111"},"msg":"Success"}
```