// Run inside the existing Node 24 Web image when the host database needs root.
// Output contains counts only; no account values or key material are printed.
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
const tables = require('./identity-tables.json');
const [sourcePath, destination] = process.argv.slice(2);
let source, target, created = false;
try {
  if (!sourcePath || !destination) throw new Error('source and destination required');
  source = new DatabaseSync(sourcePath, { readOnly: true, timeout: 5000 });
  source.exec('BEGIN');
  const version = source.prepare('PRAGMA user_version').get().user_version;
  if (![11, 12, 13].includes(version)) throw new Error('unsupported schema');
  fs.closeSync(fs.openSync(destination, 'wx', 0o600));
  created = true;
  target = new DatabaseSync(destination);
  target.exec('BEGIN; CREATE TABLE transfer_metadata (format INTEGER, source_schema INTEGER)');
  target.prepare('INSERT INTO transfer_metadata VALUES (1, ?)').run(version);
  const counts = {};
  for (const [table, columns] of Object.entries(tables)) {
    const names = columns.map(name => '"' + name + '"').join(', ');
    target.exec(`CREATE TABLE "${table}" (${names})`);
    const select = source.prepare(`SELECT ${names} FROM "${table}"`);
    select.setReadBigInts(true);
    const insert = target.prepare(`INSERT INTO "${table}" (${names}) VALUES (${columns.map(() => '?').join(', ')})`);
    let count = 0;
    for (const row of select.iterate()) { insert.run(...columns.map(column => row[column])); count++; }
    counts[table] = count;
  }
  target.exec('COMMIT');
  console.log(JSON.stringify({ status: 'ok', rows: counts }));
} catch (error) {
  if (target) { target.close(); target = null; }
  if (created) fs.unlinkSync(destination);
  console.error(`Identity export failed (${error.code || error.name}); source is unchanged.`);
  process.exitCode = 1;
} finally {
  if (target) target.close();
  if (source) source.close();
}
