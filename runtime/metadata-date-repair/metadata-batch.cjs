'use strict';
const path = require('node:path');
const core = require('./core.cjs');

function reader(req, repository, normalized) {
  const root = path.dirname(req.resolve('exiftool-vendored'));
  const { ReadTask } = req(path.join(root, 'ReadTask.js'));
  const { ExifToolTask } = req(path.join(root, 'ExifToolTask.js'));
  const tool = repository.exiftool;
  core.insist(tool && typeof tool.enqueueTask === 'function', 'unsupported-metadata-batch-runtime');
  function parse(file, record, error) {
    const task = ReadTask.for(file, tool.options);
    core.insist(typeof record?.SourceFile === 'string' && normalized(record.SourceFile) === normalized(file), 'metadata-source-mismatch');
    const tags = task.parse(JSON.stringify([record]), error);
    if (error || task.errors.length || task.warnings.length) return new core.Stop('metadata-reader-warning');
    return { tags: { ...tags, SourceFile: normalized(file) }, canonicalSourcePath: normalized(file), raw: record };
  }
  class BatchReadTask extends ExifToolTask {
    constructor(files) {
      const tasks = files.map(file => ReadTask.for(file, tool.options));
      const args = tasks[0].args.slice(0, -1);
      core.insist(tasks.every(task => core.same(task.args.slice(0, -1), args)), 'metadata-batch-options-differ');
      super([...args, '-G4', ...tasks.map(task => task.sourceFile)], tool.options);
      this.tasks = tasks;
    }
    parse(data, error) {
      const records = JSON.parse(data);
      core.insist(Array.isArray(records), 'metadata-batch-response-invalid');
      const byPath = new Map();
      for (const grouped of records) {
        // Group names protect the transport SourceFile from an image's text tag.
        const record = Object.fromEntries(Object.entries(grouped)
          .filter(([key]) => key !== ':SourceFile')
          .map(([key, value]) => [key.startsWith(':') ? key.slice(1) : key, value]));
        if (typeof record.SourceFile !== 'string') continue;
        const source = normalized(record.SourceFile);
        byPath.set(source, byPath.has(source) ? new core.Stop('metadata-batch-duplicate-source') : record);
      }
      return new Map(this.tasks.map(task => {
        const source = normalized(task.sourceFile), record = byPath.get(source);
        if (!record) return [task.sourceFile, new core.Stop('metadata-source-mismatch')];
        if (record instanceof Error) return [task.sourceFile, record];
        if (error || this.errors.length || this.warnings.length) {
          return [task.sourceFile, new core.Stop('metadata-reader-warning')];
        }
        return [task.sourceFile, parse(task.sourceFile, record)];
      }));
    }
  }
  const read = async files => {
    core.insist(Array.isArray(files) && files.length >= 1 && files.length <= 100, 'invalid-metadata-batch');
    const unique = [...new Map(files.map(file => [normalized(file), file])).values()];
    const result = await tool.enqueueTask(() => new BatchReadTask(unique));
    const byPath = new Map([...result].map(([file, metadata]) => [normalized(file), metadata]));
    return new Map(files.map(file => [file, byPath.get(normalized(file))]));
  };
  const extraction = core.hash({ version: req('exiftool-vendored/package.json').version,
    args: ReadTask.for(path.resolve('inventory-source'), tool.options).args.slice(0, -1) });
  return { read, parse, extraction };
}
module.exports = { reader };
