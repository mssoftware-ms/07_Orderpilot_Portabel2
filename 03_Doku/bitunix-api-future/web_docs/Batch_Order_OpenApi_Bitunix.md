---
content_hash: sha256:3e13013be24dcc1ab943cd95f9c0002e1ec2fc2d3dc64510c6433c0153600497
crawled_at: '2026-05-28T18:54:24.763950+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/batch_order.html
tags:
- bitunix-api-future
- web-docs
title: Batch Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/batch_order.html#VPContent)
Menu
Return to top
# Batch Order [​](https://www.bitunix.com/api-docs/futures/trade/batch_order.html#batch-order)
Rate Limit: 1 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/batch_order.html#description)
Place order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/batch_order.html#http-request)
  * POST /api/v1/futures/trade/batch_order

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/batch_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
| orderList  | list  | true  | Order list, maximum length: 5  |
| >qty  | string  | true  | Amount (base coin)  |
| >price  | string  | false  | Price of the order.Required if the order type is **LIMIT**  |
| >side  | string  | true  | Order directionbuy: **BUY** sell: **SELL**  |
| >tradeSide  | string  | true  | DirectionOnly required in hedge-modeOpen and Close Notes:For open long, side fill in"BUY"; tradeSide should be "OPEN"For open short, side fill in "SELL"; tradeSide should be "OPEN"For close long, side fill in "BUY"; tradeSide should be "CLOSE"For close short, side fill in "SELL";tradeSide should be "CLOSE"  |
| >positionId  | string  | false  | Position IDOnly required when "tradeSide" is "CLOSE"  |
| >orderType  | string  | true  | Order type**LIMIT** : limit orders**MARKET** : market orders  |
| >effect  | string  | false  | Order expiration date.Required if the orderType is limit**IOC** : Immediate or cancel**FOK** : Fill or kill**GTC** : Good till canceled(default value)**POST_ONLY** : POST only  |
| >clientId  | string  | false  | Customize order ID  |
| >reduceOnly  | boolean  | false  | Whether or not to just reduce the position  |
| >tpPrice  | string  | false  | take profit trigger price  |
| >tpStopType  | string  | false  | take profit trigger type **MARK_PRICE** **LAST_PRICE**  |
| >tpOrderType  | string  | false  | take profit trigger place order type **LIMIT** **MARKET**  |
| >tpOrderPrice  | string  | false  | take profit trigger place order price **LIMIT** **MARKET** required if tpOrderType is **LIMIT**  |
| >slPrice  | string  | false  | stop loss trigger price  |
| >slStopType  | string  | false  | stop loss trigger type **MARK_PRICE** **LAST_PRICE**  |
| >slOrderType  | string  | false  | stop loss trigger place order type **LIMIT** **MARKET**  |
| >slOrderPrice  | string  | false  | stop loss trigger place order price **LIMIT** **MARKET** required if slOrderType is **LIMIT**  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/batch_order' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","orderList":[{"side":"BUY","price":"60000","qty":"0.5","orderType":"LIMIT","reduceOnly":false,"effect":"GTC","clientId":"c12345","tpPrice":"61000","tpStopType":"MARK","tpOrderType":"LIMIT","tpOrderPrice":"61000.1","slPrice":"59000","slStopType":"LAST","slOrderType":"MARKET"},{"side":"SELL","price":"61000","qty":"0.5","orderType":"LIMIT","reduceOnly":false,"effect":"IOC","clientId":"c12346"}]}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/batch_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| successList  | list  | Successful order list  |
| >id  | string  | order id  |
| >clientId  | string  | client id  |
| failureList  | list  | Failed order list  |
| >clientId  | string  | client id  |
| >errorMsg  | string  | error msg  |
| >errorCode  | string  | error code  |
Response Example
json
```
{"code":0,"data":{"successList":[{"id":"11111","clientId":"22222"}],"failureList":[{"clientId":"22222","errorMsg":"Insufficient balance","errorCode":10012}]},"msg":"Success"}
```