export const STAFF = ['owner', 'cofounder', 'admin'];
export const isStaff = (role) => STAFF.includes(role);
export const roleLabel = (role) => (role === 'cofounder' ? 'co-founder' : role);
export const assignableRoles = (myRole) => (myRole === 'owner' ? ['member', 'admin', 'cofounder'] : isStaff(myRole) ? ['member', 'admin'] : ['member']);
