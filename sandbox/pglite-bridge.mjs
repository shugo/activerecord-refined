// The JS half of the pglite adapter.  The Ruby side asks globalThis.pglite
// for an interface, is given the name of one, and calls query() on it for
// every statement; the shape is wasmify-rails', and so is the adapter that
// talks to it.
//
// The page and check-examples.mjs get PGlite from different places -- the
// copy under assets/ and node_modules -- so it is passed in rather than
// imported here.

// PGlite's own parsers turn a value into what JS would make of it, which is
// not what ActiveRecord is about to do with it: a float would arrive at
// translate_value as a JS number and be rounded to an integer, a timestamp as
// a Date and be read back in the local zone, and jsonb as an object that
// comes out of to_s as nothing ActiveRecord can parse.  Parsing every type as
// itself hands over the text PostgreSQL wrote, which is what the pg gem would
// have handed over and what ActiveRecord's own casting expects.
// The array types have to be named: PGlite parses an array whether or not
// there is a parser registered for its type, and what it hands over then is a
// JS array, which reaches Ruby through to_s as its elements joined by commas
// -- {a,"b,c"} and {a,b,c} both arriving as "a,b,c".  Written out rather than
// worked out from the element types, since PostgreSQL's array OIDs follow no
// rule.  Anything not listed comes back as the JS value PGlite made of it,
// which for a type ActiveRecord has no column of is no worse than the text.
const ARRAY_OIDS = [
  199,   // json[]
  1000,  // boolean[]
  1005,  // smallint[]
  1007,  // integer[]
  1009,  // text[]
  1014,  // character[]
  1015,  // character varying[]
  1016,  // bigint[]
  1021,  // real[]
  1022,  // double precision[]
  1028,  // oid[]
  1115,  // timestamp[]
  1182,  // date[]
  1183,  // time[]
  1185,  // timestamptz[]
  1231,  // numeric[]
  2951,  // uuid[]
  3807,  // jsonb[]
];

function rawParsers(types) {
  const oids = [...Object.keys(types.parsers), ...ARRAY_OIDS];
  return Object.fromEntries(oids.map((oid) => [oid, (value) => value]));
}

// query() takes one statement; the schema arrives as several at once, and
// exec() is the one that takes those.  Told apart the way wasmify-rails tells
// them apart, by a statement keyword following a semicolon -- which is a guess
// about text, and a statement carrying a literal such as '; select' answers to
// it as well.  exec() takes no parameters, so that guess is only made when
// there are none to lose; a bound statement that took this path came back as
// "there is no parameter $1".
const SEVERAL = /;\s*(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE|WITH|EXPLAIN|ANALYZE|VACUUM|GRANT|REVOKE|BEGIN|COMMIT|ROLLBACK)/i;

class Interface {
  constructor(db, identifier, parsers) {
    this.db = db;
    this.identifier = identifier;
    // Given to each call rather than to PGlite.create: the array types are
    // parsed whatever the connection was opened with, and only the options of
    // the call itself are consulted for them.
    this.options = { parsers };
  }

  async query(sql, params) {
    if (!params?.length && SEVERAL.test(sql)) {
      return (await this.db.exec(sql, this.options))[0];
    }
    return await this.db.query(sql, params, this.options);
  }
}

export function createBridge({ PGlite, types }) {
  return {
    interfaces: {},

    // The name is the adapter's: it calls create_interface(database) and gets
    // back the name under which the interface it should use is on globalThis.
    async create_interface(database) {
      if (this.interfaces[database]) return this.interfaces[database].identifier;

      // No dataDir, so the database lives in memory and goes when the page
      // does -- the same bargain as the SQLite one beside it.
      const db = await PGlite.create();
      const iface = new Interface(db, `pglite_${database}`, rawParsers(types));
      globalThis[iface.identifier] = this.interfaces[database] = iface;
      return iface.identifier;
    },
  };
}
