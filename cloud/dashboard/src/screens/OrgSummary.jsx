// One muted line above the sub-tabs; "n without a lead" applies the No-lead filter.
export default function OrgSummary({ s, onNoLead }) {
  const n = (x, one, many) => `${x} ${x === 1 ? one : many}`;
  return (
    <p className="mb-4 text-sm text-muted tabular-nums">
      {n(s.activeTeams, 'active team', 'active teams')}
      {' · '}<button onClick={onNoLead} className="underline decoration-line underline-offset-4 transition-colors hover:text-fg">{s.noLead} without a lead</button>
      {' · '}{n(s.people, 'person', 'people')}
      {' · '}{s.joined} joined
    </p>
  );
}
