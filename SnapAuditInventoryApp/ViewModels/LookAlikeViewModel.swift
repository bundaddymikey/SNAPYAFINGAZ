import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
class LookAlikeViewModel {
    var groups: [LookAlikeGroup] = []
    private var modelContext: ModelContext?

    func setup(context: ModelContext) {
        self.modelContext = context
        fetchGroups()
    }

    func fetchGroups() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<LookAlikeGroup>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        groups = (try? modelContext.fetch(descriptor)) ?? []
    }

    func createGroup(name: String, notes: String = "") {
        guard let modelContext, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let group = LookAlikeGroup(name: name.trimmingCharacters(in: .whitespaces), notes: notes)
        modelContext.insert(group)
        try? modelContext.save()
        fetchGroups()
    }

    func updateGroup(_ group: LookAlikeGroup, name: String, notes: String) {
        guard let modelContext else { return }
        group.name = name.trimmingCharacters(in: .whitespaces)
        group.notes = notes
        try? modelContext.save()
        fetchGroups()
    }

    func deleteGroup(_ group: LookAlikeGroup) {
        guard let modelContext else { return }
        modelContext.delete(group)
        try? modelContext.save()
        fetchGroups()
    }

    func addMember(skuId: UUID, to group: LookAlikeGroup) {
        guard let modelContext else { return }
        if group.members.contains(where: { $0.skuId == skuId }) { return }
        removeFromAnyGroup(skuId: skuId)
        let member = LookAlikeGroupMember(skuId: skuId)
        member.group = group
        group.members.append(member)
        modelContext.insert(member)
        try? modelContext.save()
        fetchGroups()
    }

    func removeMember(_ member: LookAlikeGroupMember) {
        guard let modelContext else { return }
        modelContext.delete(member)
        try? modelContext.save()
        fetchGroups()
    }

    func removeFromAnyGroup(skuId: UUID) {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<LookAlikeGroupMember>()
        let members = (try? modelContext.fetch(descriptor)) ?? []
        for m in members where m.skuId == skuId {
            modelContext.delete(m)
        }
        try? modelContext.save()
        fetchGroups()
    }

    func setZones(_ zones: [ZoneRect], for group: LookAlikeGroup) {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ZoneProfile>()
        let allProfiles = (try? modelContext.fetch(descriptor)) ?? []
        if let existing = allProfiles.first(where: { $0.groupId == group.id }) {
            existing.zones = zones
        } else {
            let profile = ZoneProfile(groupId: group.id)
            profile.zones = zones
            modelContext.insert(profile)
        }
        try? modelContext.save()
    }

    func zoneProfile(for group: LookAlikeGroup) -> ZoneProfile? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<ZoneProfile>()
        let allProfiles = (try? modelContext.fetch(descriptor)) ?? []
        return allProfiles.first { $0.groupId == group.id }
    }

    func groupFor(skuId: UUID) -> LookAlikeGroup? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<LookAlikeGroupMember>()
        let members = (try? modelContext.fetch(descriptor)) ?? []
        return members.first { $0.skuId == skuId }?.group
    }

    func memberFor(skuId: UUID, in group: LookAlikeGroup) -> LookAlikeGroupMember? {
        group.members.first { $0.skuId == skuId }
    }
}
