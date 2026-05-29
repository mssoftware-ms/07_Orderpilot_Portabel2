---
content_hash: sha256:f56e84d3b7f0d3e919709adf35ad65aea3d2b4ce81032e7464f313606d730891
crawled_at: '2026-05-28T18:54:24.564318+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html
tags:
- bitunix-api-future
- web-docs
title: Asset Query | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html#VPContent)
Menu
Return to top
# Asset Query [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html#asset-query)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html#description)
Interface is used to asset query.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html#http-request)
  * GET /api/v1/cp/asset/query

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/cp/asset/query' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "timestamp:1659076670000" \
   -H "nonce:your-nonce" \
   -H "language:en-US"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/asset_query.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| available  | string  | Futures available  |
| maxTransfer  | string  | Maximum transfer amount  |
Response Example
json
```
{"code":0,"msg":"result.success","data":{"available":"54.20916","maxTransfer":"52.20916"},"success":true}
```