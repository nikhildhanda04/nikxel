import { Tip } from '../ui.jsx';

// One muted line above the sub-tabs; "n without a lead" applies the No-lead filter.
export default function OrgSummary({ s, onNoLead }) {
  const n = (x, one, many) => `${x} ${x === 1 ? one : many}`;
  return (
    <p className="mb-4 text-sm text-muted tabular-nums">
      <Tip tip="Not archived here and still active in the ERP" tap><span>{n(s.activeTeams, 'active team', 'active teams')}</span></Tip>
      {' · '}<Tip tip="Active teams with no lead — click to show them"><button onClick={onNoLead} className="underline decoration-line underline-offset-4 transition-colors hover:text-fg">{s.noLead} without a lead</button></Tip>
      {' · '}<Tip tip="Everyone imported from the ERP" tap><span>{n(s.people, 'person', 'people')}</span></Tip>
      {' · '}<Tip tip="Linked to a Nikxel account" tap><span>{s.joined} joined</span></Tip>
    </p>
  );
}
