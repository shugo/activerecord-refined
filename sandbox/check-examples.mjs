// Runs every example through the same code path the page uses and prints the
// output, so the examples can be checked without opening a browser.
import { boot, run } from './harness.mjs';
import { examples } from './examples.js';

const wasm = process.argv[2] ?? './ruby.wasm';

const vm = await boot(wasm);

let failures = 0;
for (const group of examples) {
  for (const item of group.items) {
    const out = run(vm, item.code);
    const unexpected = /^(NoMethodError|NameError|SyntaxError|TypeError):/m.test(out);
    if (unexpected) failures++;

    console.log('='.repeat(72));
    console.log(`${group.group} / ${item.title}${unexpected ? '   <-- UNEXPECTED ERROR' : ''}`);
    console.log('='.repeat(72));
    console.log(out.trimEnd());
    console.log();
  }
}

console.log(failures === 0 ? 'All examples ran.' : `${failures} example(s) raised an unexpected error.`);
process.exit(failures === 0 ? 0 : 1);
