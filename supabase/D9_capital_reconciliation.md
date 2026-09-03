# D9 — Capital Return vs Base Unit Cost (Reconciliation Note)

**Test case:** Hyundai Grand Avega White (unit 62, `funding_model=perkasa`), settled 2026-09-02.

## Two distinct figures — both correct, and they *should* differ

| Concept | Amount | Source of truth |
|---|---|---|
| **Capital Returned / Capital Rotation** | Rp 84.200.000 | `unit_settlement.total_capital_return` = `perkasa_funding_snap` (the `unit_funding` `perkasa` entry) |
| **Base Unit Cost** | Rp 84.550.000 | `unit_settlement.base_unit_cost_snap` = Σ `unit_cost_entries` (Purchase 84.2M + Service 250K + Transport 100K) |

The Rp84.2M is **genuinely Perkasa Funding** — the capital principal deployed to
acquire the unit — so on sale it rotates back as Capital Returned. It is **not**
profit (capital return ≠ profit).

The 350K gap (Base Cost − Capital Return) = Service 250K + Transport 100K. These
acquisition costs were paid from operating cash, not from a capital drawdown, so
they correctly do **not** rotate back, yet they **are** included in Base Unit Cost
and therefore already expensed against profit.

## Profit chain (unchanged from D5/D6)

- True Unit Profit = Net Proceeds 89.0M − Base Unit Cost 84.55M = **4.45M**
- Cash Reserve allocation (10% of positive profit) = **445K**
- Operating Profit Pool (90%) = **4.005M**

Capital Rotation (84.2M) and Realized Profit (4.45M) are reported on separate
lines and never summed together.

**Conclusion:** source of truth is correct; no fix required. Rp84.2M is
documented as Capital Returned / Capital Rotation.
