interface PromptOptions {
  title: string;
  message?: string;
  placeholder?: string;
  value?: string;
  buttons: string[];
  multiline?: boolean;
}

declare global {
  interface Window {
    nikxelPrompt: { init(): Promise<PromptOptions>; answer(button: number, value: string): void };
  }
}

const api = window.nikxelPrompt;
const opts = await api.init();
document.getElementById("title")!.textContent = opts.title;
const msg = document.getElementById("message")!;
if (opts.message) msg.textContent = opts.message; else msg.remove();

const field = document.createElement(opts.multiline ? "textarea" : "input");
field.placeholder = opts.placeholder ?? "";
field.value = opts.value ?? "";
document.getElementById("field")!.replaceWith(field);
if (opts.multiline) field.parentElement!.style.flex = "1";

const cancel = opts.buttons.length - 1;
const answer = (i: number) => api.answer(i, field.value.trim());
const row = document.getElementById("buttons")!;
opts.buttons.forEach((title, i) => {
  const b = document.createElement("button");
  b.textContent = title;
  if (i === 0) b.className = "default";
  b.onclick = () => answer(i);
  row.appendChild(b);
});

document.addEventListener("keydown", e => {
  if (e.key === "Escape") answer(cancel);
  if (e.key === "Enter" && !(opts.multiline && !e.ctrlKey)) { e.preventDefault(); answer(0); }
});
field.focus();

export {};
