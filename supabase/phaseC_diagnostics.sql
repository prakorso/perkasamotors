-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE C · DEBT/PAYROLL DIAGNOSTICS (read-only)
-- Run this to trace WHY the app reports errors like public.debts /
-- public.payroll_people. Interpret the results with the guide at the bottom.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Do the tables exist?  (expect 7 rows: debts, debt_payments, fee_payments,
--    payroll_people, payroll_rules, payroll_obligations, payroll_payments)
select table_name from information_schema.tables
where table_schema='public'
  and table_name in ('debts','debt_payments','fee_payments',
                     'payroll_people','payroll_rules','payroll_obligations','payroll_payments')
order by table_name;

-- 2) Do the views exist?  (expect 9)
select table_name from information_schema.views
where table_schema='public'
  and table_name in ('v_debt_summary','v_debt_schedule','v_payroll_summary',
                     'v_payroll_obligations','v_partner_fee_payable','v_liabilities',
                     'v_upcoming_obligations','v_cash_pool','v_safe_cash')
order by table_name;

-- 3) Do the RPCs exist?  (expect 5)
select routine_name from information_schema.routines
where routine_schema='public'
  and routine_name in ('pm_payroll_basis_value','pm_payroll_run','pm_payroll_pay',
                       'pm_debt_build_schedule','pm_debt_pay')
order by routine_name;

-- 4) Are grants present for anon/authenticated on the new tables?
--    (each table should show anon + authenticated with the CRUD privileges)
select table_name, grantee, string_agg(privilege_type,',' order by privilege_type) as privs
from information_schema.role_table_grants
where table_schema='public'
  and table_name in ('debts','debt_payments','fee_payments',
                     'payroll_people','payroll_rules','payroll_obligations','payroll_payments')
  and grantee in ('anon','authenticated')
group by table_name, grantee
order by table_name, grantee;

-- 5) RLS policies present? (each table should have an allow_all policy)
select tablename, policyname from pg_policies
where schemaname='public'
  and tablename in ('debts','debt_payments','fee_payments',
                    'payroll_people','payroll_rules','payroll_obligations','payroll_payments')
order by tablename;

-- ══════════════════════════════════════════════════════════════════════════
-- INTERPRETATION
--   • Query 1/2/3 return FEWER rows than expected
--        → the Phase 9/10/11 migrations were not (fully) run. Run, in order:
--          phase9_debt.sql → phase10_payroll.sql → phase11_cash_pool.sql
--   • Queries 1–3 are complete BUT the app still errors "public.debts ...
--     schema cache"
--        → PostgREST's schema cache is stale. Reload it:
--             NOTIFY pgrst, 'reload schema';
--          (or toggle any setting in Dashboard → API to force a reload; the
--           cache also refreshes on its own within ~1 minute.)
--   • Query 4 missing anon/authenticated rows → grants not applied; re-run the
--     GRANT block at the end of the relevant phase file.
--   • Query 5 missing a policy → RLS enabled without a policy; re-run the
--     policy block. (App logs in as anon, so an allow-all policy is required.)
-- ══════════════════════════════════════════════════════════════════════════
