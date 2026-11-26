/// A What's new tour step inside a meeting summary: dashboardWindow opens the newest meeting and
/// parks the step here; that page's widget (pageShare /coach) shows it, then /coach-done hands the
/// tour back. Its own module so pageShare needn't import the window. Port of DashboardWindowController.coach.
export const TourCoach = {
  pending: null as { file: string; step: Record<string, unknown> } | null,
  /// Set by dashboardWindow: carry on with the tour (or end it, on Skip).
  resume: (_skip: boolean): void => {},
};
