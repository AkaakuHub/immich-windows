'use strict';
const path = require('node:path');
const core = require('./core.cjs');

function reader(req, repository, normalized) {
  const root = path.dirname(req.resolve('exiftool-vendored'));
  const { ReadTask } = req(path.join(root, 'ReadTask.js'));
  const { ExifToolTask } = req(path.join(root, 'ExifToolTask.js'));
  const tool = repository.exiftool;
  core.insist(tool && typeof tool.enqueueTask === 'function', 'unsupported-metadata-batch-runtime');
  class BatchReadTask extends ExifToolTask {
    constructor(files) {
      const tasks = files.map(file => ReadTask.for(file, tool.options));
      const args = tasks[0].args.slice(0, -1);
      core.insist(tasks.every(task => core.same(task.args.slice(0, -1), args)), 'metadata-batch-options-differ');
      super([...args, ...tasks.map(task => task.sourceFile)], tool.options);
      this.tasks = tasks;
    }
    parse(data, error) {
      const records = JSON.parse(data);
      core.insist(Array.isArray(records) && records.length === this.tasks.length, 'metadata-batch-count-mismatch');
      const byPath = new Map();
      for (const record of records) {
        core.insist(typeof record.SourceFile === 'string', 'metadata-source-mismatch');
        const source = normalized(record.SourceFile);
        core.insist(!byPath.has(source), 'metadata-batch-duplicate-source');
        byPath.set(source, record);
      }
      return new Map(this.tasks.map(task => {
        const source = normalized(task.sourceFile), record = byPath.get(source);
        core.insist(record, 'metadata-source-mismatch');
        const tags = task.parse(JSON.stringify([record]), error);
        if (error || this.errors.length || this.warnings.length || task.errors.length || task.warnings.length) {
          return [task.sourceFile, new core.Stop('metadata-reader-warning')];
        }
        return [task.sourceFile, { tags: { ...tags, SourceFile: source }, canonicalSourcePath: source }];
      }));
    }
  }
  return async files => {
    core.insist(Array.isArray(files) && files.length >= 1 && files.length <= 100, 'invalid-metadata-batch');
    const unique = [...new Set(files.map(normalized))];
    const result = await tool.enqueueTask(() => new BatchReadTask(unique));
    return new Map(files.map(file => [file, result.get(normalized(file))]));
  };
}
module.exports = { reader };
