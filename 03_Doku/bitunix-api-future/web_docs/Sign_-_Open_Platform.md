---
content_hash: sha256:cf2b4efc0b7663843c1ce45669a1c5943bfa421e241cf5dbf4b6cac00bbe7608
crawled_at: '2026-05-28T18:54:25.011831+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/sign/
tags:
- bitunix-api-future
- web-docs
title: Sign - Open Platform
tool_used: crawl4ai
---

# Sign
### Signature Introduction[¶](https://www.bitunix.com/api-docs/spots/en_us/sign/#signature-introduction "Permanent link")
#### Restful API Signature Public Parameters[¶](https://www.bitunix.com/api-docs/spots/en_us/sign/#restful-api-signature-public-parameters "Permanent link")
**Headers:**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| api-key  | string  | Y  | api-key applied  |
| nonce  | string  | Y  | Random string，32bits  |
| timestamp  | string  | Y  | Current timestamp, milliseconds  |
| sign  | string  | Y  | Singanture string  |
Signature steps:
>   1. All queryParams are sorted in ascending ASCII order by Key, Example: String queryParams = "id=1uid=200"
>   2. Parameters in body, compressed into a string, **remember to remove all spaces** , Example：String body = {"uid":"2899","arr":[{"id":1,"name":"maple"},{"id":2,"name":"lily"}]}
>   3. Signature, needs to be encrypted 2 times
>>      * String digest = SHA256(nonce + timestamp + api-key + queryParams + body)
>>      * String sign = SHA256(digest + secretKey)
>>      * Note: secretKey is together when applying for api-key. Please keep them safely and do not pass it around.
>

#### WebSocket API Singature Parameters[¶](https://www.bitunix.com/api-docs/spots/en_us/sign/#websocket-api-singature-parameters "Permanent link")
WebSocket API requests require authentication, and the following fields need to be included in all request parameter `params`:
| Name  | Type  | Mandatory  | Description  |
| --- | --- | --- | --- |
| `apiKey`  | string  | Y  | API Key  |
| `timestamp`  | string  | Y  | Timestapmp  |
| `nonce`  | string  | Y  | Random string  |
| `sign`  | string  | Y  | Signature string  |
Signature steps:
>   1. Sort all fields in `params` except the `sign`, `apiKey`, `timestamp`, `nonce` fields in ascending ASCII order by Key, **remember to remove all spaces** , Example: String params = "symbolBTC"
>   2. Signature, needs to be encrypted 2 times
>>      * String digest = SHA256(nonce + timestamp + apiKey + params)
>>      * String sign = SHA256(digest + secretKey)
>>      * Note: secretKey is together when applying for apiKey. Please keep them safely and do not pass it around.
>