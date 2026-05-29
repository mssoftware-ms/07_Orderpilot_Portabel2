---
content_hash: sha256:59e019e955e82593d1e0b7f62ce44509ead3d9c8dad81ee8a41005a9f4c81adc
crawled_at: '2026-05-28T18:54:24.850525+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html
tags:
- bitunix-api-future
- web-docs
title: Modify Position TP/SL Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html#VPContent)
Menu
Return to top
# Modify Position TP/SL Order [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html#modify-position-tp-sl-order)
Rate Limit: 10 req/sec/UID
### Description [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html#description)
Modify Position TP/SL Order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html#http-request)
  * POST /api/v1/futures/tpsl/position/modify_order

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
| positionId  | string  | true  | Position ID associated with take-profit and stop-loss  |
| tpPrice  | string  | false  | Take-profit trigger priceAt least one of `tpPrice` or `slPrice` is required.  |
| tpStopType  | string  | false  | Take-profit trigger typeLAST_PRICEMARK_PRICE Default is market price.  |
| slPrice  | string  | false  | Stop-loss trigger priceAt least one of `tpPrice` or `slPrice` is required.  |
| slStopType  | string  | false  | Stop-loss trigger typeLAST_PRICEMARK_PRICE Default is market price.  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/tpsl/position/modify_order' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","positionId":"11","tpPrice":"12","tpStopType":"LAST_PRICE","slPrice":"9","slStopType":"LAST_PRICE"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/modify_position_tp_sl_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderId  | string  | TP/SL Order ID  |
Response Example
json
```
{"code":0,"data":{"orderId":"11111"},"msg":"Success"}
```