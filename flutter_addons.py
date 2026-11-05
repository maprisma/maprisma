"""Signed service-side adapters, independent of the GTK icon/widget loader.

The existing verifier and adapter API remain the trust boundary. GTK feature and
extension UI contracts have not been ported, so those add-ons are listed without
executing them or changing their saved enabled state.
"""
from __future__ import annotations

import addon_api
import addons
import harnesses
import providers

SUPPORTED = frozenset(("agent", "provider"))


class AdapterRegistry:
    def __init__(self):
        self.items: list[addons.Addon] = []
        self.hooks = addon_api.Hooks()

    def reload(self, enabled: set[str]) -> None:
        self.hooks.clear()
        harnesses.remove_added()
        providers.remove_added()
        self.items = [addons.verify(path) for path in addons.find()]
        verified = [item for item in self.items if item.state == "verified"]
        harnesses.hide_built_in({key for item in verified if item.kind == "agent" for key in item.provides})
        providers.hide_built_in({key for item in verified if item.kind == "provider" for key in item.provides})
        for item in verified:
            if item.kind in SUPPORTED and item.id in enabled:
                addons.load(item, self.hooks)
        harnesses.changed()
        providers.changed()

    def snapshot(self, enabled: set[str]) -> dict:
        import agents
        installed = [a for a in agents.list_agents() if a.installed]
        def sign_ins(item):
            if item.kind != 'provider':return []
            commands = {c for key in item.provides if (p := providers.get(key)) is not None and p.kind == 'online' for c in p.agents}
            return [{'command':a.command,'name':a.name} for a in installed if a.command in commands and (h:=harnesses.get(a.command)) is not None and h.access]
        return {"addons": [{
            "id": item.id, "name": item.name or item.id, "version": item.version,
            "summary": item.summary, "description": item.description,
            "kind": item.kind, "state": item.state,
            "enabled": item.id in enabled, "loaded": item.state == "loaded",
            "supported": item.kind in SUPPORTED,
            "verified": item.state in ("verified", "loaded", "failed"),
            "reads": item.reads, "sends": item.sends,
            "privacy": item.privacy, "capabilities": item.capabilities,
            "provides": item.provides,
            "sign_ins": sign_ins(item),
            "removable": item.folder.parent == addons.USER_DIR and not item.folder.is_symlink(),
            "legacy": item.reason == addons.LEGACY_REASON,
        } for item in self.items]}

    def installed(self, enabled: set[str]) -> set[str]:
        import agents
        import inventory
        adapter_ids = {item.id for item in self.items if item.kind in SUPPORTED
                       and item.state in ("verified", "loaded")}
        found = set()
        try:
            self.reload(enabled | adapter_ids)
            processes = inventory.own_processes()
            for item in self.items:
                if item.id not in adapter_ids or item.state != "loaded":
                    continue
                if item.kind == "provider" and len(item.provides) > 1:
                    found.add(item.id)  # the same online-provider group as the legacy welcome page
                for key in item.provides[:1]:
                    if item.kind == "agent" and agents.detect(key)[0]:
                        found.add(item.id)
                    provider = providers.get(key) if item.kind == "provider" and len(item.provides) == 1 else None
                    if provider and provider.detect and provider.detect(processes).installed:
                        found.add(item.id)
        finally:
            self.reload(enabled)
        return found
