-- 1. ghost from stop_component BEFORE stop_entity
test "component stopped before entity stop replicates removal after revive"
    start_entity(e); start_component(e, C)
    collect_updates(A)                     -- A saw C, last_replicated has A
    stop_component(e, C)
    stop_entity(e)
    start_entity(e)                        -- C not restarted
    assert member_sees_removal(A, e, C)
    assert not entity_removed_sent(A, e)   -- A covered before and after: no entity delta

-- 2. ghost from stop_component AFTER stop_entity
test "component stopped while entity dead replicates removal after revive"
    start_entity(e); start_component(e, C)
    collect_updates(A)
    stop_entity(e)
    stop_component(e, C)                   -- dead-entity branch, postponed entry -> GHOST
    start_entity(e)
    assert member_sees_removal(A, e, C)

-- 3. ghost overwritten by restart while dead
test "component restarted while entity dead is revived normally, no removal"
    start_entity(e); start_component(e, C)
    collect_updates(A)
    stop_entity(e)
    stop_component(e, C)                   -- GHOST
    start_component(e, C)                  -- overwrites GHOST with normal postponed
    start_entity(e)
    assert not member_sees_removal(A, e, C)   -- A still covered, delta nets to zero
    assert component_active(e, C)

-- 4. never-replicated component started+stopped while dead
test "component born and killed while entity dead leaves nothing"
    start_entity(e)
    collect_updates(A)
    stop_entity(e)
    start_component(e, C)                  -- postponed only
    stop_component(e, C)                   -- no last_replicated entry -> postponed entry removed
    start_entity(e)
    assert no_deltas_for(e, C)
    assert postponed_components[e] is nil after revive

-- 5. regression: normal postponed revival untouched
test "active component postponed and revived keeps working"
    start_entity(e); start_component(e, C, filter_F)
    collect_updates(A)
    stop_entity(e); start_entity(e)
    assert component_active(e, C) with filter_F
    assert not member_sees_removal(A, e, C)

-- 6. entity stays dead: wipe still holds
test "no component removed deltas while entity dead"
    start_entity(e); start_component(e, C)
    collect_updates(A)
    stop_component(e, C)
    stop_entity(e)
    assert entity_removed_delta_exists(A, e)
    assert no component_removed_delta(e, C) in any storage   -- wiped, only ghost marker

-- 7. ghost + member leaving entity filter on revive
test "member excluded by new entity filter gets entity removal, ghost harmless"
    start_entity(e); start_component(e, C)
    collect_updates(A, B)
    stop_component(e, C)
    stop_entity(e)
    start_entity(e, filter = exclude A)
    assert entity_removed_sent(A, e)
    assert member_sees_removal(B, e, C)    -- B stays: needs component removal

-- 8. ghost + member gone (newly_unactive)
test "unactive member excluded from ghost removed delta"
    start_entity(e); start_component(e, C)
    collect_updates(A)
    stop_component(e, C); stop_entity(e)
    unregister/deactivate(A)               -- A in newly_unactive
    start_entity(e)
    assert no removed delta targets A

-- 9. ghost with empty last_replicated
test "component never replicated before stop leaves no delta"
    start_entity(e)
    collect_updates(A)
    start_component(e, C)                  -- started after cycle, last_replicated = empty
    stop_component(e, C)                   -- before next collect
    stop_entity(e); start_entity(e)
    assert no_deltas_for(e, C)             -- empty -> empty, update_storage_delta_changes no-ops

-- 10. double stop/start cycle, ghost consumed once
test "ghost cleared after first revival"
    start_entity(e); start_component(e, C)
    collect_updates(A)
    stop_component(e, C); stop_entity(e)
    start_entity(e)
    collect_updates(A)                     -- removal delivered, deltas consumed
    stop_entity(e); start_entity(e)
    assert not member_sees_removal(A, e, C)   -- no stale ghost second time

-- 11. filtered component ghost hits only members that saw it
test "ghost removal respects component filter history"
    start_entity(e)
    start_component(e, C, filter = only A)   -- B never sees C
    collect_updates(A, B)
    stop_component(e, C); stop_entity(e)
    start_entity(e)
    assert member_sees_removal(A, e, C)
    assert not member_sees_removal(B, e, C)

-- 12. mixed: one ghost, one postponed, same entity
test "ghost and live component coexist through revive"
    start_entity(e); start_component(e, C1); start_component(e, C2)
    collect_updates(A)
    stop_component(e, C1)
    stop_entity(e)                         -- C1 ghost, C2 postponed
    start_entity(e)
    assert member_sees_removal(A, e, C1)
    assert component_active(e, C2)
    assert not member_sees_removal(A, e, C2)

-- 13. end-to-end: new member joins after revive
test "ghost produces no additions for new members"
    start_entity(e); start_component(e, C)
    collect_updates(A)
    stop_component(e, C); stop_entity(e)
    register+activate(B)
    start_entity(e)
    assert not member_sees_addition(B, e, C)   -- ghost only ever produces removals
