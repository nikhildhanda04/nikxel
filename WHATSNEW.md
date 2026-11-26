# What's new in Nikxel

<!--
The app reads this file: it's What's new in the Nikxel window, and the tour that runs once
the first time someone opens Nikxel after updating (and again from Show me).
- Each update is a `## YYYY-MM-DD` heading, newest first.
- Each change under it is a `### Title`, then a short paragraph written to the user.
- `tour:` lines under a change are its tour, one step each, in order:
      tour: <section> | <title> | <text>
  The tour opens that section and points at it in the sidebar. Title and text are optional;
  without them the step shows the change's own title and paragraph. A new feature gets a
  step for each place and option the user should know; a fix usually gets none.
  Sections: home, chat, library, tasks, automations, people, activity, whatsnew, you,
  meetings, whatsapp, connections, advanced, and the organization's org-home, org-chart,
  org-projects, org-roles, org-shared, org-connection, and meeting: a step shown inside the newest
  meeting summary, pointing at its Push to dashboard bar.
-->

## 2026-11-27.3

### Push a meeting to your dashboard in one click
Every meeting page has **Push to dashboard** at the top. I pick the project I think the meeting is from: one named in the minutes, or where this meeting went last time. If I'm wrong, choose another from the list beside it. One click sends it, without the client summary or transcript, and the page shows where it went. **See what's sent** shows exactly what leaves your computer.
tour: library | Your meetings | Every meeting summary is here. Open one and Push to dashboard is near the top.
tour: meeting | Push to dashboard | I picked the project I think this meeting is from. Wrong? Choose another from the list. Then one click pushes it to that project on your dashboard.

## 2026-11-27.2

### Give me documents to read
Drop a document or image on Chat, or press **+** beside the box, and I read it right here on your computer: PDF, Word, text, and the words in a picture. Ask about it, or use it to set something up. It stays part of that chat.
tour: chat | Drop a file here | Drag a PDF, Word file or image onto the chat, or press + beside the box. I read it on your computer, then answer from it.

### Automations that follow your format
An automation can keep a file to follow every time, like your SOP format. Say it in Chat with the file attached (“after every client meeting, write an SOP in this format”), or attach it under **Files it follows** when you edit an automation. It can be for some meetings only: I check each one and skip the rest. If I skipped one you wanted, choose **Run on…** and pick the meeting. **Copy** under a run puts its text on your clipboard.
tour: automations | Files it follows | Edit an automation and attach a file under Files it follows: a template or SOP format I use every time it runs.
tour: automations | Run on… | Next to an automation for meetings, Run on… lets you pick any meeting, even one it skipped. Copy under a run takes its text.

### Reminders that really happen
Say “remind me tomorrow morning to send the deck” in Chat and I add it to Automations as a one-time automation. It runs once, then switches itself off. You can make one yourself too: pick **Once, on a day** when you set when it runs. If your computer is asleep then, it runs as soon as you're back.
tour: chat | Ask me to remind you | Say “remind me tomorrow at 10 to call Vikas”. I tell you exactly when, and it's added to Automations.
tour: automations | One-time automations | Reminders show here as Temporary. After they run they say Done and switch off. Choose Once, on a day to make your own.

### Bubbles wait for you
The day summary, reminders and questions no longer fade while you're away from your computer. They wait until you're back, and one arriving while another is up waits its turn instead of being lost.

### Several organizations, like Slack workspaces
You can be in more than one organization. Under Organizations in the sidebar, pick one to open it. Inside, the name at the top switches between them, and **+** starts or joins another. Each has its own people, roles and projects, and what you send goes only to the one you're in.
tour: org-home | Switch organizations | The name at the top of this sidebar switches between your organizations. Press + beside it to start a new one or join with an invite link.
tour: org-connection | Organizations | Every organization you're in and your role in each. Switch here, rename one you own, or leave one.

### Roles you design
Owners can make their own roles and choose what each can do: invite people, change roles, see every project, read teammates' days, and see every project in chat. Rename or delete them, or add one like “Project lead”. Nobody can give a role more than their own role has. The owner can also hand the organization over: open someone in the Org chart and choose **Make owner**.
tour: org-roles | Roles you design | Tick what each role can do, rename it, or add a new one at the bottom. Changes apply right away.
tour: org-chart | Hand over or promote | Drag people between levels to change their role. Open someone to make them the owner.

### Your ERP projects, in one click
Organization → Projects can bring in the ERP projects where you have a task or gave someone one. You see the list and untick any before anything is sent.
tour: org-projects | Bring in your ERP projects | Choose Find them under Bring in your ERP projects. Untick any you don't want, then add the rest.

### Your avatar, head to toe
An avatar made from your photo is now drawn full body, legs and shoes included, in my style.

## 2026-11-27

### Edit summary templates right here
Recording & notes → Templates → **Edit…** opens your templates in this window. Untick sections you don't need, set the length and tone, add a section of your own, or switch to **Write it** and type it out. **New…** starts one from scratch or from a copy.
tour: meetings | Summary templates | Under Templates, choose Edit… to change how your minutes are written, or New… to make one for a kind of meeting.

### Connect any ERP
Connections → ERP now asks for your ERP's web address. Type it, choose **Open sign-in**, and log in in the window that opens; I keep the login and close the window. You can change the address or disconnect there too.
tour: connections | Your ERP | Under ERP, type your ERP's address and choose Open sign-in. Change or disconnect it here any time.

## 2026-11-26

### What's new, right here
tour: whatsnew
Every update now lists what it added in this section. Choose **Show me** under an update to see its tour again.

### Chat works with your ERP
tour: chat
Ask “what's pending for Aarib?” and I read the open tasks in Forklyft ERP right then. Say “draft a task for …” and I make it, with the assignee and reviewer you name, then open it for you to check.

### Automations can check ERP tasks
tour: automations
An automation like “every morning, nudge developers about pending tasks” now reads the real open tasks, who they're for and when they're due, instead of guessing from notes.

### Your organization, from the app
Organization in the sidebar is your team's side of Nikxel: who's in it, its projects, roles, and everything you've shared, right in this window.
tour: org-home | Your organization | Your team's side of Nikxel. The overview shows how many people and projects there are, and exactly what can leave your computer.
tour: org-chart | Org chart | Everyone by level. Drag people between levels to change their role, or onto a project to add them. Click anyone for the details.
tour: org-projects | Projects | The projects you're on. Open one to read what your teammates shared to it, day by day.
tour: org-roles | Roles | What each role can do. Owners tick, rename or add roles; changes apply right away.
tour: org-shared | Shared by me | Every meeting and day you've sent to the team. Unshare anything here.
tour: org-connection | Connection | How this computer is linked to your organization. Disconnect to stop sharing from here, or leave.

### Regenerated summaries open here
A summary you regenerate from Recording & notes now opens in this window, not in your browser.

### Renaming a summary finishes
Naming a summary no longer gets stuck on “Renaming…”. Older summaries pick up the fix the next time Nikxel starts.

## 2026-11-25

### The Nikxel window
tour: home
Everything from the menu bar now lives here: Home, your Library of summaries, Chat, Tasks, People and every setting.

### Chat opens your summaries
tour: library
Ask “open my last meeting” and it opens here in a tab, ready to read, share, edit or rename.

### Gmail in chat
Chat can search your inbox, draft replies and tidy labels. It never sends anything unless you say “send it”.
