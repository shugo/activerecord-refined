// Bundled to vendor/editor.js by bin/prepare-rb.  CodeMirror is a dozen ESM
// packages with bare specifiers, so the page cannot load it directly the way
// it loads everything else here.
//
// What reaches the page is one function returning the two things it needs --
// read the code, replace the code -- so index.html has no CodeMirror in it.
import { EditorView, basicSetup } from 'codemirror';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { ruby } from 'codemirror-lang-ruby';
import { oneDark } from '@codemirror/theme-one-dark';

export function createEditor({ parent, doc = '', onRun }) {
  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc,
      extensions: [
        // Ahead of basicSetup's own keymap, so Enter does not win first.
        keymap.of([
          { key: 'Mod-Enter', preventDefault: true, run: () => (onRun(), true) },
        ]),
        basicSetup,
        ruby(),
        oneDark,
        EditorView.theme({
          '&': { height: '100%', fontSize: '13px', borderRadius: '6px' },
          '.cm-scroller': { fontFamily: 'inherit', lineHeight: '1.55' },
        }),
      ],
    }),
  });

  return {
    get value() {
      return view.state.doc.toString();
    },
    set value(text) {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        selection: { anchor: 0 },
      });
    },
    focus() {
      view.focus();
    },
  };
}
