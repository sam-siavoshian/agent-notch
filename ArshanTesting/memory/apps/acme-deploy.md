# Acme Deploy UI Memory

## App Profile
Acme Deploy is a synthetic SaaS deployment dashboard used to test UI/UX learning.

## Surfaces Seen
- [high] Dashboard overview: Overview surface with deployment health cards, activity feed, and left navigation. (evidence: fixture-overview)
- [high] Deployments table: Deployments table with environment, status, commit, age, and filters. (evidence: fixture-deployments)
- [high] Deployments filters open: Filter popover is open with status options including Failed. (evidence: fixture-filters-open)
- [high] Failed deployment detail: Failed deployment detail panel showing production API deployment failure and logs. (evidence: fixture-failed-detail)

## Landmarks
- [high] left navigation (evidence: fixture-overview)
- [high] health cards (evidence: fixture-overview)
- [high] activity feed (evidence: fixture-overview)
- [high] top search (evidence: fixture-overview)
- [high] deployments selected in sidebar (evidence: fixture-deployments)
- [high] status filter (evidence: fixture-deployments)
- [high] center deployment table (evidence: fixture-deployments)
- [high] filter popover (evidence: fixture-filters-open)
- [high] status options (evidence: fixture-filters-open)
- [high] deployments table behind popover (evidence: fixture-filters-open)
- [high] right detail panel (evidence: fixture-failed-detail)
- [high] red failed status (evidence: fixture-failed-detail)
- [high] error log excerpt (evidence: fixture-failed-detail)

## Affordances
- [high] Open deployments from left navigation (evidence: fixture-overview)
- [high] Search projects from top bar (evidence: fixture-overview)
- [high] Click Status filter to narrow by failed deployments (evidence: fixture-deployments)
- [high] Click a row to open deployment detail (evidence: fixture-deployments)
- [high] Select Failed to narrow the table (evidence: fixture-filters-open)
- [high] Apply filters to confirm (evidence: fixture-filters-open)
- [high] Use View logs for details (evidence: fixture-failed-detail)
- [high] Copy error for sharing (evidence: fixture-failed-detail)
- [high] Redeploy after fixing env (evidence: fixture-failed-detail)

## Transitions
- [high] overview -- click Deployments in the left navigation --> deployments (evidence: fixture-overview, fixture-deployments)
- [high] deployments -- click Status filter --> filters-open (evidence: fixture-deployments, fixture-filters-open)
- [high] filters-open -- select Failed status --> failed-detail (evidence: fixture-filters-open, fixture-failed-detail)

## Task Recipes
- [high] Find failed deployment: open Deployments, use Status filter, select Failed, then inspect the failed deployment detail. (evidence: fixture-overview, fixture-deployments, fixture-filters-open, fixture-failed-detail)

## Negative Memory
- [high] click blank center area: Blank center area is not actionable. (evidence: fixture-overview)

## Stale / Uncertain Notes
- [medium] Blank center card area may not be directly actionable. (evidence: fixture-overview)
- [medium] Some dashboards may apply the filter immediately after selecting Failed. (evidence: fixture-filters-open)
