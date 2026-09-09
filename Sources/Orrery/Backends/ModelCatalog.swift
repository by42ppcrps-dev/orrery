import Foundation

/// One answer to "which models and reasoning efforts can this provider run", for every picker
/// — the Solo toolbar, Team roles and Roundtable seats. Sources, in order: the live list a
/// running session reported; the CLI's own model cache on disk (Codex and Grok refresh theirs
/// at every launch, so a model that shipped this morning is here before any session starts);
/// then a short known list for aliases the CLIs do not enumerate. Nothing here is a guess
/// frozen in the source: the known lists only fill gaps.
@MainActor
enum ModelCatalog {
    struct Entry: Equatable {
        var option: ModelOption
        var efforts: [String]
    }

    /// Overridable so audits can point at fixture caches.
    static var codexCacheURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/models_cache.json")
    static var grokCacheURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/models_cache.json")

    static let knownCodex = [
        ModelOption(id: "gpt-6-astra", name: "GPT-6-Astra"),
        ModelOption(id: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
        ModelOption(id: "gpt-5.6-terra", name: "GPT-5.6-Terra"),
        ModelOption(id: "gpt-5.6-luna", name: "GPT-5.6-Luna"),
        ModelOption(id: "gpt-5.5", name: "GPT-5.5"),
        ModelOption(id: "gpt-5.4-mini", name: "GPT-5.4-Mini"),
    ]
    static let knownGrok = [
        ModelOption(id: "grok-4.6", name: "Grok 4.6"),
        ModelOption(id: "grok-4.5", name: "Grok 4.5"),
    ]
    static let effortVocabulary: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let defaultEfforts: [Provider: [String]] = [
        .claude: ["low", "medium", "high", "xhigh", "max"],
        .grok: ["low", "medium", "high", "xhigh"],
        .codex: ["low", "medium", "high", "xhigh", "max", "ultra"],
    ]

    static func known(_ provider: Provider) -> [ModelOption] {
        switch provider {
        case .claude: return ClaudeBackend.knownVersions
        case .codex: return knownCodex
        case .grok: return knownGrok
        }
    }

    /// The CLI's cached catalog: Codex lists `models[].slug` with `supported_reasoning_levels`;
    /// Grok keys `models` by id with an `info` block and effort ids nested below it. Empty when
    /// there is no cache or it does not parse.
    static func cached(_ provider: Provider) -> [Entry] {
        switch provider {
        case .codex:
            guard let data = try? Data(contentsOf: codexCacheURL), let json = JSON(data: data) else { return [] }
            return json["models"].array.compactMap { model in
                guard let slug = model["slug"].string, !slug.isEmpty else { return nil }
                let efforts = model["supported_reasoning_levels"].array.compactMap { $0["effort"].string }
                return Entry(option: ModelOption(id: slug, name: model["display_name"].string ?? slug), efforts: efforts)
            }
        case .grok:
            guard let data = try? Data(contentsOf: grokCacheURL), let json = JSON(data: data),
                  let models = json["models"].raw as? [String: Any] else { return [] }
            return models.keys.sorted(by: >).map { id in
                let node = JSON(models[id])
                let name = node["info"]["name"].string ?? id
                return Entry(option: ModelOption(id: id, name: name), efforts: effortIDs(in: models[id]))
            }
        case .claude:
            return []
        }
    }

    /// Effort ids anywhere under a model node, in the order found ("id": "xhigh" …).
    private static func effortIDs(in value: Any?) -> [String] {
        var found: [String] = []
        func walk(_ any: Any?) {
            if let dictionary = any as? [String: Any] {
                if let id = dictionary["id"] as? String, effortVocabulary.contains(id), !found.contains(id) { found.append(id) }
                for child in dictionary.values { walk(child) }
            } else if let array = any as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
        return found
    }

    /// Models to offer: the live list first when a session reported one, then the CLI's cache,
    /// then the known list for anything still missing. No duplicates; order preserved.
    static func choices(_ provider: Provider, live: [ModelOption]? = nil) -> [ModelOption] {
        var result: [ModelOption] = []
        var seen = Set<String>()
        func add(_ options: [ModelOption]) {
            for option in options where !seen.contains(option.id) { seen.insert(option.id); result.append(option) }
        }
        if let live, !live.isEmpty { add(live) }
        add(cached(provider).map(\.option))
        add(known(provider))
        return result
    }

    /// Efforts for one model as the CLI's cache lists them, else the provider's full set.
    static func efforts(_ provider: Provider, model: String? = nil) -> [String] {
        if let model, !model.isEmpty, let entry = cached(provider).first(where: { $0.option.id == model }), !entry.efforts.isEmpty {
            return entry.efforts
        }
        return defaultEfforts[provider] ?? []
    }

    static func name(_ provider: Provider, of id: String) -> String {
        choices(provider).first { $0.id == id }?.name ?? id
    }
}

extension AppModel {
    /// The picker list for a provider: live models when this window's session reported them.
    func modelChoices(for provider: Provider) -> [ModelOption] {
        ModelCatalog.choices(provider, live: states[provider]?.hasReportedModels == true ? backends[provider]?.models : nil)
    }
}
