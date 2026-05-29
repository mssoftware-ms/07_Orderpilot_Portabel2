---
content_hash: sha256:d568de270b43770afb44be4020c715cb6efb29ab451151158cd0a731ef18204a
crawled_at: '2026-05-28T18:54:24.597353+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/account/get_single_account.html
tags:
- bitunix-api-future
- web-docs
title: Get Single Account | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/account/get_single_account.html#VPContent)
Menu
Return to top
# Get Single Account [​](https://www.bitunix.com/api-docs/futures/account/get_single_account.html#get-single-account)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/account/get_single_account.html#description)
Get account details with the given 'marginCoin'
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/account/get_single_account.html#http-request)
  * GET /api/v1/futures/account

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/account/get_single_account.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| marginCoin  | string  | true  | Margin coin  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/account?marginCoin=USDT' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/account/get_single_account.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| marginCoin  | string  | Margin Coin  |
| available  | string  | Available quantity in the account. This field + crossUnrealizedPNL = Actual maximum open amount  |
| frozen  | string  | locked quantity of orders  |
| margin  | string  | locked quantity of positions  |
| transfer  | string  | Maximum transferable amount  |
| positionMode  | string  | Position mode **ONE_WAY** **HEDGE**  |
| crossUnrealizedPNL  | string  | unrealizedPNL for cross positions  |
| isolationUnrealizedPNL  | string  | unrealizedPNL for isolation positions  |
| bonus  | string  | Futures Bonus  |
Response Example
json
```
{"code":0,"data":[{"marginCoin":"USDT","available":"1000","frozen":"0","margin":"10","transfer":"1000","positionMode":"HEDGE","crossUnrealizedPNL":"2","isolationUnrealizedPNL":"0","bonus":"0"}],"msg":"Success"}
```