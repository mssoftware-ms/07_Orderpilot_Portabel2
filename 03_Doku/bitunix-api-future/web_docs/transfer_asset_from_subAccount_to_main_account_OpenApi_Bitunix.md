---
content_hash: sha256:c1023f1cd156a4323fae0e0c2fb2f2a9e0ac0e4361b7e748797563f5837c1883
crawled_at: '2026-05-28T18:54:24.513129+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html
tags:
- bitunix-api-future
- web-docs
title: transfer asset from subAccount to main account | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html#VPContent)
Menu
Return to top
# transfer asset from subAccount to main account [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html#transfer-asset-from-subaccount-to-main-account)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html#description)
Interface is used to transfer asset from subAccount to main Account.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html#http-request)
  * POST /api/v1/cp/asset/transfer-to-main-account

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| amount  | string  | true  | transfer amount  |
| assetType  | string  | true  | Assets are transferred to the futures account or spot account of the main account. eg: SOPT/FUTURES  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/cp/asset/transfer-to-main-account' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "timestamp:1659076670000" \
   -H "nonce:your-nonce" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"amount":"10","assetType":"SPOT"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_subaccount_to_main_account.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
Response Example
json
```
{"code":0,"msg":"result.success","data":"","success":true}
```