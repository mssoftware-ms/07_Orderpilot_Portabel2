---
content_hash: sha256:74661cffd196af0c1c7088eb0768ff63e2e2d2cea5e97c14343f68e65487d2ae
crawled_at: '2026-05-28T18:54:25.038779+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/user/
tags:
- bitunix-api-future
- web-docs
title: User - Open Platform
tool_used: crawl4ai
---

# User
##  [Quick Guide](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#quick-guide "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#restful-api "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#public-interface "Permanent link")
### User Interface[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#user-interface "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#websocket-api "Permanent link")
###  [WebSocket Guide](https://www.bitunix.com/api-docs/spots/en_us/ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#websocket-guide "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#public-interface_1 "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#user-interface_1 "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#order-interface_1 "Permanent link")
#### 1. Checking account balance[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#1-checking-account-balance "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> GET: /api/spot/v1/user/account
**Request Parameters**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| None  |
**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object[]  | N  | Account Information  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| coin  | string  | Y  | Token  |
| balance  | number  | Y  | Balance  |
| balanceLocked  | number  | Y  | In Use  |
#### 2. Get user information[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#2-get-user-information "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> GET: /api/spot/v1/user/info
**API Description**
  * Requires [signature](https://www.bitunix.com/api-docs/spots/en_us/sign/) authentication and returns information for the user bound to the current API key.
  * You can also use **WebSocket** with `method` = `user.info`; the `data` shape matches below—see [User Interface (WebSocket)](https://www.bitunix.com/api-docs/spots/en_us/user-ws/).
  * **`uid`**: The user identifier in the Open API. With a**master** account API key, this is that master account’s `uid`. With a **sub-account** API key, this is the `uid` of the **linked master account** (so integrations can align on one user id per master account).
  * If the user or linked master account cannot be resolved, the response follows [error codes](https://www.bitunix.com/api-docs/spots/en_us/err_code/).
  * `uid` may be `null`; rely on the actual response and handle nulls in your integration.

**Request Parameters**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| None  |
**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | User information  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| uid  | int64  | N  | User `uid`; with a sub-account API key, the linked master account `uid`; may be null  |

```
{
    "code": "0",
    "msg": "result.success",
    "data": {
        "uid": 681979174
    },
    "success": true
}

```

#### 3. Submit withdrawal request[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#3-submit-withdrawal-request "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/withdraw
**API Description**
  * You can only withdraw to address or accounts that have added under quick-withdrawal. You can set up the quick-withdrawal address on the webesite or application.A
  * Tag or MEMO: Some tokens like XRP will require a Tag or MEMO, or payment_id. This is the only string that matching your deposit address. Please make sure you have enter the correct information, otherwise your assets may be lost.
  * Only the apikey that has enabled withdrawal permission can be used to withdraw. Otherwise it will be rejected.

**Request Parameters（Rules: 10 times/1 second(IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| coin  | string  | Y  | TokenYou can get this in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) Interface  |
| network  | string  | Y  | Network  |
| address  | string  | Y  | Withdrawal address  |
| amount  | decimal  | Y  | Withdrawal amountWithdrawal Amount(Withdrawal amount - fee = Actual amount) Decimals can be found in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface.  |
| memo  | string  | N  | Tag or memo  |

```
{
    "coin": "TRX",
    "network": "Tron (TRC-20)",
    "address": "TJmW5D1p1LnMdTMmxuY1VELHht7v5HV7rU",
    "amount": 20.00
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Withdrawal Order ID  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| withdrawId  | string  | Y  | WIthdrawal Order ID  |

```
{
    "code": "0",
    "msg": "result.success",
    "data": "1909879608889339906",
    "success": true
}

```

#### 4. Cancel Withdrawal[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#4-cancel-withdrawal "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/withdraw/cancel
**API Description**
  * When it's under manual review and on the intial reviewing stage, it can be canceled Once it's approved or it's on the network, it can't be canceled.

**Request Parameters（Rules: 10 times/1 second(IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| withdrawId  | string  | Y  | Withdrawal Order ID  |

```
{
    "withdrawId": "1909879608889339906"
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Null  |

```
{
    "code": "0",
    "msg": "result.success",
    "data": null,
    "success": true
}

```

#### 5. Initiate Internal Transfer[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#5-initiate-internal-transfer "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/inside_transfer
**API Description**
  * Only the apikey that has enabled withdrawal permission can be used to withdraw. Otherwise it will be rejected.

**Request Parameters（Rules: 10 times/1 second(IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| outBizId  | string(32)  | N  | External service provider business ID, used as an idempotency parameter.  |
| coin  | string  | Y  | TokenYou can get this in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface  |
| amount  | decimal  | Y  | Transfer amountDecimals can be found in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData)  |
| toType  | string  | Y  | Method`uid` via UID `phone` via mobile number `email` via email  |
| toUid  | int64  | N  | UID  |
| toPhoneCountryCode  | string  | N  | Area code  |
| toPhoneNumber  | string  | N  | Mobile number  |
| toEmail  | string  | N  | Email address  |
| remark  | string(256)  | N  | Remark  |

```
{
    "coin": "USDT",
    "amount": 10,
    "toType": "uid",
    "toUid": 681979174
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | string  | Y  | Internal Transfer Order ID  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| insideTransferId  | string  | Y  | Order ID  |

```
 {
    "code": "0",
    "msg": "result.success",
    "data": "1909921053381820417",
    "success": true
}

```

#### 6. Cancel Internal Transfer[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#6-cancel-internal-transfer "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/inside_transfer/cancel
**API Description**
  * When it's under manual review and on the intial reviewing stage, it can be canceled Once it's approved, it can't be canceled.

**Request Parameters（Rules: 10 times/1 second(IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| insideTransferId  | string  | Y  | Internal Transfer Order ID It can be acquired by using [RequestInternalTransfer](https://www.bitunix.com/api-docs/spots/en_us/user/#RequestInternalTransfer) interface  |

```
{
    "insideTransferId": "1909921053381820417"
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | description  |
| data  | object  | N  | Order ID  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| insideTransferId  | string  | Y  | Order ID  |

```
 {
    "code": "0",
    "msg": "result.success",
    "data": null,
    "success": true
}

```

#### 7. Request Withdrawal History(Withdrawal and Internal Transfer Included)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#7-request-withdrawal-historywithdrawal-and-internal-transfer-included "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/withdraw_transfer/page
**Request Parameters（Rules: 10 times/1 second(IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| id  | string  | N  | Withdrawal Order ID / Internal Transfer Order ID  |
| outBizId  | string  | N  | External service provider business ID  |
| coin  | string  | N  | TokenYou can get this in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface  |
| transactionHash  | string  | N  | TxIDValid only when the type is `withdraw`  |
| type  | string  | N  | Withdrawal Type`withdraw` = Withdrawal`inside_transfer_out` = Internal Transfer  |
| startTime  | int64  | N  | Starting time of the request, Unix timestamp, e.g., 1597026383085  |
| endTime  | int64  | N  | Ending time of the request, Unix timestamp, e.g., 1597026683085  |
| remark  | string  | N  | Remark (Precise query)  |
| limit  | int32  | N  | Number of results. Default: 100. Maximum: 100. Returns 100 if not specified.  |

```
{
    "id": "1909877667383767042",
    "limit": 10
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Withdrawal / Internal Transfer Records  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| id  | string  | Y  | Withdrawal Order ID / Internal Transfer Order ID  |
| outBizId  | string  | N  | External service provider business ID  |
| coin  | string  | Y  | Token Name  |
| network  | string  | Y  | Network  |
| amount  | decimal  | Y  | Actual Receiving Amount  |
| feeCoin  | string  | Y  | Fee Token  |
| fee  | decimal  | Y  | Fee  |
| type  | string  | Y  | Type`withdraw`: On-chain withdrawal`inside_transfer_out`: Internal Transfer  |
| toAddress  | string  | N  | Address（It will only be returned when `type=withdraw`）  |
| transactionHash  | string  | N  | TxID (It will only be returned when `type=withdraw`）  |
| toType  | string  | N  | Method `uid`：Via ID `phone`：Via Mobile Number `email`：Via Email  |
| toUid  | int64  | N  | Receiving UID（It will only be returned when `toType=uid`）  |
| toPhoneCountryCode  | string  | N  | Area Code（It will only be returned when `toType=phone`）  |
| toPhoneNumber  | string  | N  | Mobile（It will only be returned when `toType=phone`）  |
| toEmail  | string  | N  | Email（It will only be returned when`toType=email`）  |
| remark  | string(256)  | N  | Remark  |
| status  | string  | Y  | Status `verification`：Pending user security authentication (security verification needs to be done in the client's withdrawal list). `pending`：Pending `cancelled`：Cancelled `success`：Completed `fail`：Failed  |
| ctime  | int64  | Y  | Time of the request creation，Unix timestamp. For example：`1597026383085`  |

```
{
    "code": "0",
    "msg": "result.success",
    "data": [
        {
            "id": "1909877667383767042",
            "outBizId": "123456789",
            "type": "withdraw",
            "coin": "TRX",
            "amount": "19.00000000000000000000",
            "status": "pending",
            "ctime": 1744185294000,
            "network": "Tron (TRC-20)",
            "address": "TJmW5D1p1LnMdTMmxuY1VELHht7v5HV7rU",
            "transactionHash": null,
            "feeCoin": null,
            "fee": null,
            "memo": null,
            "toType": null,
            "toUid": null,
            "toPhoneCountryCode": null,
            "toPhoneNumber": null,
            "toEmail": null,
            "remark": null
        }
    ],
    "success": true
}

```

#### 8. Transfer[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#8-transfer "Permanent link")
> [Siganature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/funds_transfer
**API Description**
  * Transfer of different types of fudns within personal account. For example, transfering funds from spot account to futures account.

**Request Parameters（Rules: 10 times/1 second(IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| type  | string  | Y  | Transfer Type`spot_futures` From spot account to futures account`futures_spot` From futures account to spot account  |
| coin  | String  | Y  | TokenYou can get this in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface  |
| amount  | decimal  | Y  | Transfer amountDecimals can be found in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface  |

```
{
    "type": "spot_futures",
    "coin": "USDT",
    "amount": 100.01
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | string  | Y  | Transfer Order ID  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| transferId  | string  | Y  | Transfer Order ID  |

```
{
    "code": "0",
    "msg": "result.success",
    "data": "1909902180506972162",
    "success": true
}

```

#### 9. Get Deposit Records (On-chain Deposit + Internal Transfer)[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#9-get-deposit-records-on-chain-deposit-internal-transfer "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/deposit/page
**API Description**
**Request Parameters (Rate Limit: 10 requests/second per IP)**
| Parameter Name  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| id  | string  | No  | Deposit ID / Transfer ID  |
| coin  | string  | No  | CoinYou can obtain it via the [Query Coin Info](https://www.bitunix.com/api-docs/spots/en_us/public/#%E6%9F%A5%E8%AF%A2%E5%B8%81%E7%A7%8D%E6%95%B0%E6%8D%AE) API  |
| type  | string  | No  | Deposit Type`deposit`: On-chain deposit`inside_transfer_in`: Internal transfer  |
| transactionHash  | string  | No  | Transaction hash (applies only for `deposit`)  |
| startTime  | int64  | No  | Query start time, Unix timestamp, e.g., 1597026383085  |
| endTime  | int64  | No  | Query end time, Unix timestamp, e.g., 1597026683085  |
| limit  | int32  | No  | Number of records to return, maximum 100, default is 100 if not provided  |

```
{
  "type": "",
  "transactionHash": "",
  "coin": "USDT",
  "limit": 10 
}

```

**Response Data**
| Name  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| code  | number  | Yes  |
| msg  | string  | Yes  | Description  |
| data  | object  | No  | Withdrawal / Transfer Records  |
**data**
| Name  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| id  | string  | Yes  | Deposit ID / Transfer ID  |
| transactionHash  | string  | No  | Transaction ID (returned only when `type=deposit`)  |
| coin  | string  | Yes  | Coin name  |
| network  | string  | No  | Network (returned only when `type=deposit`)  |
| type  | string  | Yes  | Deposit type`deposit`: On-chain deposit`inside_transfer_in`: Internal transfer  |
| fromAddress  | string  | Yes  | Sender address`deposit`: On-chain sender address`inside_transfer_in`: Sender user ID  |
| toAddress  | string  | Yes  | Recipient address`deposit`: On-chain recipient address`inside_transfer_in`: Recipient user ID  |
| amount  | decimal  | Yes  | Actual credited amount  |
| status  | string  | Yes  | Deposit status `pending`: Processing `cancelled`：cancel `success`: Successful `fail`: Failed  |
| ctime  | int64  | Yes  | Creation time, Unix timestamp, e.g., `1597026383085`  |

```
{
  "code": "0",
  "msg": "Success",
  "data": [
   {
      "id": 1909903708907155457,
      "transactionHash": null,
      "coin": "USDT",
      "network": null,
      "type": "inside_transfer_in",
      "fromAddress": "989541187",
      "toAddress": "681979174",
      "amount": "10.00000000",
      "status": "pending",
      "ctime": 1744191503000
    },
    {
      "id": 1909903532977074178,
      "transactionHash": null,
      "coin": "USDT",
      "network": null,
      "type": "inside_transfer_in",
      "fromAddress": "989541187",
      "toAddress": "681979174",
      "amount": "10.00000000",
      "status": "pending",
      "ctime": 1744191461000
    },
    {
      "id": 487067,
      "transactionHash": "d829e32be84907a4dfb5bee5dcdaee6b637be287f8db52817860e7169003b92d",
      "coin": "USDT",
      "network": "Tron (TRC-20)",
      "type": "deposit",
      "fromAddress": "TB73gtW1hsTxxA9XUYKLSJKTSHw6Jk53eH",
      "toAddress": "TPKhSAEy84qvpomF5wF7h5ih1WmbmupXor",
      "amount": "1000.00000000",
      "status": "success",
      "ctime": 1742892246000
    }
  ],
  "success": true
}

```

#### 10. Get Deposit Address[¶](https://www.bitunix.com/api-docs/spots/en_us/user/#10-get-deposit-address "Permanent link")
> [Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/)
> HTTP Request
> POST: /api/spot/v1/deposit/address
**Request Parameters (Rate Limit: 10 requests/second per IP)**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| coin  | string  | Y  | TokenYou can get this in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface  |
| network  | string  | Y  | NetworkYou can get this in [QueryTokenData](https://www.bitunix.com/api-docs/spots/en_us/public/#QueryTokenData) interface  |

```
{
    "coin": "USDT",
    "network": "Tron (TRC-20)"
}

```

**Return**
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object[]  | N  | Deposit Address List  |
data
| Parameter  | Type  | Mandatory  | Notes  |
| --- | --- | --- | --- |
| coin  | string  | Y  | Token  |
| network  | string  | Y  | Network  |
| address  | string  | Y  | Deposit Address  |
| memo  | string  | N  | Memo/Tag  |

```
{
    "code": "0",
    "msg": "result.success",
    "data": [
        {
            "coin": "USDT",
            "network": "Tron (TRC-20)",
            "address": "TPKhSAEy84qvpomF5wF7h5ih1WmbmupXor",
            "memo": null
        }
    ],
    "success": true
}

```