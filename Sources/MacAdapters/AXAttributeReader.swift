// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import LayoutCore
import ApplicationServices

enum AXReadValueError: Error, Equatable, CustomStringConvertible {
    case emptyValue(operation: String)
    var description: String {
        switch self { case .emptyValue(let operation): return lk("%@：AX 返回成功但没有值", "\(operation)") }
    }
}
enum AXAttributeReader {
    static func read(operation: String, copy: (inout CFTypeRef?) -> AXError) throws -> CFTypeRef {
        var value: CFTypeRef?
        let status=copy(&value)
        guard status == .success else { throw AXFailure(operation:operation,code:status.rawValue) }
        guard let value else { throw AXReadValueError.emptyValue(operation:operation) }
        return value
    }
}
