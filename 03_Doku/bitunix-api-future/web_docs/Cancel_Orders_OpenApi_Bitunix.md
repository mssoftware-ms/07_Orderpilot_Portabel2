---
content_hash: sha256:796c252d550b81b4f6ee3b3a8a8adc8f6ea23e2a3851ab08bea0f73259729cab
crawled_at: '2026-05-28T18:54:24.780294+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html
tags:
- bitunix-api-future
- web-docs
title: Cancel Orders | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html#VPContent)
Menu
Return to top
# Cancel Orders [​](https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html#cancel-orders)
Rate Limit: 5 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html#description)
Cancel ordersSuccessful interface response is not necessarily equal to the success of the operation, please use the websocket push message as an accurate judgment of the success of the operation.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html#http-request)
  * POST /api/v1/futures/trade/cancel_orders

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
| orderList  | list  | true  | order parameter list  |
| orderId  | string  | false  | Order IDEither orderId or clientId is required. If both are entered, orderId prevails.  |
| clientId  | string  | false  | Customize order IDEither orderId or clientId is required. If both are entered, orderId prevails.  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/cancel_orders' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","orderList":[{"orderId":"11111"},{"clientId":"22223"}]}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/cancel_orders.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| successList  | list  | Successful order list  |
| >id  | string  | order id  |
| >clientId  | string  | client id  |
| failureList  | list  | Failed order list  |
| >id  | string  | order id  |
| >clientId  | string  | client id  |
| >errorMsg  | string  | error msg  |
| >errorCode  | string  | error code  |
Response Example
json
```
{"code":0,"data":{"successList":[{"orderId":"11111","clientId":"22222"}],"failureList":[{"orderId":"11112","clientId":"22223","errorMsg":"Order status error","errorCode":10013}]},"msg":"Success"}
```