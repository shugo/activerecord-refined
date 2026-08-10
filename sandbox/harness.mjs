// Boots the sandbox exactly the way index.html does -- same WASI shim, same
// writable in-memory root -- so anything that passes here works in the browser.
import { readFile } from 'node:fs/promises';
import { File, OpenFile, PreopenDirectory, WASI } from '@bjorn3/browser_wasi_shim';
import { RubyVM } from '@ruby/wasm-wasi/dist/vm';

export async function boot(wasmPath, { rbDir = './rb/lib', bootPath = './boot.rb' } = {}) {
  const wasi = new WASI([], [], [
    new OpenFile(new File([])),
    new OpenFile(new File([])),
    new OpenFile(new File([])),
    new PreopenDirectory('/', new Map()),
  ], { debug: false });

  const module = await WebAssembly.compile(await readFile(wasmPath));
  const { vm } = await RubyVM.instantiateModule({ module, wasip1: wasi });

  const manifest = JSON.parse(await readFile('./manifest.json', 'utf8'));
  const sources = {};
  for (const rel of manifest) sources[rel] = await readFile(`${rbDir}/${rel}`, 'utf8');
  installFiles(vm, '/rb/lib', sources);

  vm.eval(await readFile(bootPath, 'utf8'));
  return vm;
}

// Nothing under rb/lib is packed into the binary.  Its sources are handed to
// Ruby, which writes them into the in-memory filesystem and puts that on
// $LOAD_PATH.  That is what makes activerecord-refined loadable at all -- the
// rbwasm output is already wasi-vfs packed and cannot be packed again, and the
// gem's required_ruby_version keeps Bundler on the host from resolving it --
// and it means the gem can be swapped without rebuilding the 64 MB binary.
export function installFiles(vm, root, sources) {
  const entries = Object.entries(sources)
    .map(([rel, src]) => `[${rubyString(rel)}, ${rubyString(src)}]`)
    .join(",\n");

  vm.eval(`
    require 'fileutils'
    [
      ${entries}
    ].each do |rel, src|
      path = File.join(${rubyString(root)}, rel)
      FileUtils.mkdir_p File.dirname(path)
      File.write path, src
    end
    $LOAD_PATH.unshift ${rubyString(root)}
  `);
}

function rubyString(s) {
  // A Ruby single-quoted literal only gives \\ and \' special meaning.
  return "'" + s.replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
}

export function run(vm, code) {
  const nonce = 'SANDBOX_' + Math.random().toString(36).slice(2) + '_END';
  return vm.eval(`
begin
  require 'stringio'
  __buf = StringIO.new
  __prev = $stdout
  $stdout = __buf
  begin
    eval(<<'${nonce}', TOPLEVEL_BINDING, '(sandbox)', 1)
${code}
${nonce}
  rescue Exception => e
    __buf.puts "#{e.class}: #{e.message}"
  ensure
    $stdout = __prev
  end
  __buf.string.sub(/\\n+\\z/, "\\n")
end
`).toString();
}
