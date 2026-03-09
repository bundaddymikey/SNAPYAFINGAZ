import Foundation
import SwiftData

struct DemoDataService {
    static func loadDemoData(context: ModelContext) {
        let existingUsers = (try? context.fetch(FetchDescriptor<AppUser>())) ?? []
        guard existingUsers.isEmpty else { return }

        let salt = PINService.generateSalt()
        let adminPin = PINService.hash(pin: "1234", salt: salt)
        let admin = AppUser(name: "Demo Admin", role: .admin, pinHash: adminPin, pinSalt: salt)
        context.insert(admin)

        let auditorSalt = PINService.generateSalt()
        let auditorPin = PINService.hash(pin: "5678", salt: auditorSalt)
        let auditor = AppUser(name: "Demo Auditor", role: .auditor, pinHash: auditorPin, pinSalt: auditorSalt)
        context.insert(auditor)

        let warehouse = Location(name: "Main Warehouse", notes: "Primary storage facility")
        let storeA = Location(name: "Store Front A", notes: "Retail display area")
        let backroom = Location(name: "Back Room", notes: "Overflow storage")
        context.insert(warehouse)
        context.insert(storeA)
        context.insert(backroom)

        let products: [(sku: String, name: String, brand: String, category: String, variant: String, tags: [String])] = [
            ("SNK-001", "Protein Bar", "FitFuel", "Snacks", "Chocolate", ["food", "protein"]),
            ("SNK-002", "Protein Bar", "FitFuel", "Snacks", "Peanut Butter", ["food", "protein"]),
            ("SNK-003", "Trail Mix", "NaturePath", "Snacks", "Classic", ["food", "nuts"]),
            ("SNK-004", "Granola Bites", "CrunchCo", "Snacks", "Honey Oat", ["food", "granola"]),
            ("ELC-001", "USB-C Charger", "VoltEdge", "Electronics", "30W", ["charging", "usb-c"]),
            ("ELC-002", "Lightning Cable", "VoltEdge", "Electronics", "6ft", ["cable", "apple"]),
            ("ELC-003", "Wireless Earbuds", "SoundCore", "Electronics", "Black", ["audio", "bluetooth"]),
            ("ELC-004", "Phone Case", "ShieldMax", "Electronics", "Clear", ["accessory", "protection"]),
            ("TOL-001", "Shampoo", "CleanCraft", "Toiletries", "12oz", ["hair", "hygiene"]),
            ("TOL-002", "Hand Soap", "CleanCraft", "Toiletries", "8oz Lavender", ["soap", "hygiene"]),
            ("TOL-003", "Toothpaste", "BrightSmile", "Toiletries", "Mint 4oz", ["dental", "hygiene"]),
            ("TOL-004", "Deodorant", "FreshGuard", "Toiletries", "Sport", ["hygiene", "body"]),
            ("BEV-001", "Sparkling Water", "BubblePure", "Beverages", "Lemon 12pk", ["drink", "water"]),
            ("BEV-002", "Energy Drink", "ZapEnergy", "Beverages", "Original 16oz", ["drink", "energy"]),
            ("SUP-001", "Notebooks", "PageMaster", "Supplies", "College Rule 3pk", ["paper", "office"]),
            ("SUP-002", "Ballpoint Pens", "WriteRight", "Supplies", "Blue 10pk", ["pen", "office"]),
        ]

        for p in products {
            let product = ProductSKU(
                sku: p.sku,
                name: p.name,
                brand: p.brand,
                category: p.category,
                variant: p.variant,
                tags: p.tags
            )
            context.insert(product)

            let link = ProductLocationLink(product: product, location: warehouse)
            context.insert(link)
        }

        try? context.save()
    }

    static func clearAllData(context: ModelContext) {
        try? context.delete(model: SampledFrame.self)
        try? context.delete(model: CapturedMedia.self)
        try? context.delete(model: AuditSession.self)
        try? context.delete(model: ProductLocationLink.self)
        try? context.delete(model: ProductSKU.self)
        try? context.delete(model: Location.self)
        try? context.delete(model: AppUser.self)
        try? context.save()
    }
}
