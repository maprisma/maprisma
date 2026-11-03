"""First-run adapter selection without GTK or implicit program installation."""
from __future__ import annotations

from pathlib import Path

import ai_core
import settings_schema
from flutter_addons import SUPPORTED, AdapterRegistry


def apply(registry: AdapterRegistry, path: Path | None, selected, locked=frozenset()) -> dict:
    if (not isinstance(selected, list) or len(selected) > 200
            or not all(isinstance(item, str) for item in selected) or len(set(selected)) != len(selected)):
        raise ValueError('Invalid setup selection')
    available = {item.id for item in registry.items if item.kind in SUPPORTED
                 and item.state in ('verified', 'loaded')}
    if set(selected) - available:
        raise ValueError('Unavailable setup selection')
    before = set(settings_schema.value(ai_core.load_settings(path), 'addons_enabled'))
    managed = {item.id for item in registry.items if item.kind in SUPPORTED}
    if ((before & managed) - set(selected)) & set(locked):
        # A running agent's own add-on is not switched off.
        raise ValueError('Finish running agents before changing add-ons')
    # Preserve feature/extension choices and add-ons absent from this installation.
    enabled = (before - managed) | set(selected)
    try:
        registry.reload(enabled)
        loaded = {item.id for item in registry.items if item.state == 'loaded'}
        if set(selected) - loaded:
            raise ValueError('An adapter could not be loaded')
        ai_core.update_settings(path, addons_enabled=sorted(enabled), setup_done=True)
    except Exception:
        registry.reload(before)
        raise
    return registry.snapshot(enabled)
