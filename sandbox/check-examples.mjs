// Runs every example through the same code path the page uses and prints the
// output, so the examples can be checked without opening a browser.
import { boot, run, useDatabase } from './harness.mjs';
import { examples } from './examples.js';

const wasm = process.argv[2] ?? './ruby.wasm';

const vm = await boot(wasm);

// An example that prints nothing is not showing anything, whatever it says it
// is showing.  The one that caught this built a relation and never asked for
// its SQL, so the failure it was written to demonstrate never happened.
const complaint = (out) => {
  if (out.trim() === '') return 'PRINTS NOTHING';
  if (/^(NoMethodError|NameError|SyntaxError|TypeError):/m.test(out)) return 'UNEXPECTED ERROR';
  return null;
};

let failures = 0;

// A missing or repeated slug is not visible in the page: it puts #undefined in
// the URL, or gives two examples the same link and opens whichever came last.
const slugs = new Map();
for (const group of examples) {
  for (const item of group.items) {
    if (!item.slug) {
      console.log(`NO SLUG: ${group.group} / ${item.title}`);
      failures++;
    } else if (slugs.has(item.slug)) {
      console.log(`SLUG '${item.slug}' IS ALSO ${slugs.get(item.slug)}`);
      failures++;
    } else {
      slugs.set(item.slug, item.title);
    }
  }
}

// Both databases: the page offers both, and an example that says what
// PostgreSQL makes of it has to have been run there to be worth saying.
for (const database of ['sqlite3', 'postgresql']) {
  await useDatabase(vm, database);

  console.log('#'.repeat(72));
  console.log(`# ${database}`);
  console.log('#'.repeat(72));
  console.log();

  for (const group of examples) {
    for (const item of group.items) {
      const out = await run(vm, item.code);
      const wrong = complaint(out);
      if (wrong) failures++;

      console.log('='.repeat(72));
      console.log(`${database} / ${group.group} / ${item.title}${wrong ? `   <-- ${wrong}` : ''}`);
      console.log('='.repeat(72));
      console.log(out.trimEnd());
      console.log();
    }
  }
}

console.log(failures === 0 ? 'All examples ran.' : `${failures} example(s) went wrong.`);
process.exit(failures === 0 ? 0 : 1);
