---
content_hash: sha256:a3ccbe2f922137fa1ce1de2f7efea3f5ac9cadff7391ab8065572bd5337daa13
crawled_at: '2026-05-28T18:54:24.624567+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html
tags:
- bitunix-api-future
- web-docs
title: Adjust Position Margin | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html#VPContent)
Menu
Return to top
# Adjust Position Margin [​](https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html#adjust-position-margin)
Rate Limit: 5 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html#description)
Add or reduce the margin（only for isolated margin mode）
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html#http-request)
  * POST /api/v1/futures/account/adjust_position_margin

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
| marginCoin  | string  | true  | Margin coin  |
| amount  | string  | true  | Margin amount, positive means increase, and negative means decrease  |
| side  | string  | false  | Position side **LONG** **SHORT** Either side or positionId required  |
| positionId  | string  | false  | Position id Either side or positionId required  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/account/adjust_position_margin' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","amount":"-100","marginCoin":"USDT","side":"LONG"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/account/adjust_position_margin.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
Response Example
json
```
{"code":0,"data":"","msg":"Success"}
```