import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Fill nullable confirm fields. Omitted lines are kept as stored by hestia.
/// Import review can also leave the stored shop name and NIP unchanged.
struct ExplicitNullsMiddleware: ClientMiddleware {
    var preserveStoredReceiptFields = false

    /// operationID → (top-level keys, keys of each element of `lines`).
    static let required: [String: (top: [String], lines: [String])] = [
        "confirmBudgetReceipt": (
            top: ["receipt_id", "expected_version", "raw_shop_name", "raw_nip", "receipt_kind", "receipt_date",
                  "receipt_time", "total_amount", "currency", "payment_method", "lines", "link"],
            lines: ["line_kind", "raw_name", "ptu_code", "quantity", "raw_unit", "unit_price_raw",
                    "gross_line_total", "discount_amount", "net_line_total"]
        ),
    ]
    /// confirm's body cap on the server is 128 KiB; never buffer more than that.
    static let maxBody = 128 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let keys = Self.required[operationID], let body else {
            return try await next(request, body, baseURL)
        }
        let data = try await Data(collecting: body, upTo: Self.maxBody)
        let top = preserveStoredReceiptFields ? ["receipt_time", "link"] : keys.top.filter { $0 != "lines" }
        let patched = try Self.fill(data, top: top, lines: keys.lines)
        var request = request
        request.headerFields[.contentLength] = String(patched.count)
        return try await next(request, HTTPBody(patched), baseURL)
    }

    static func fill(_ data: Data, top: [String], lines: [String]) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        for key in top where object[key] == nil { object[key] = NSNull() }
        if let items = object["lines"] as? [[String: Any]] {
            object["lines"] = items.map { item in
                var item = item
                for key in lines where item[key] == nil { item[key] = NSNull() }
                return item
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
