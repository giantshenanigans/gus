import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { safePath } from '../tools.mjs';

// Imports tools.mjs for real rather than reimplementing the check: pg's Pool is
// lazy, so pulling in db.mjs opens no connection and this stays DB-free.

const WORKSPACE_ROOT = '/home/openclaw/.openclaw/workspace';
const rejects = /Path outside workspace not allowed/;

describe('safePath', () => {
  it('accepts a plain relative path', () => {
    assert.equal(safePath('AGENTS.md'), `${WORKSPACE_ROOT}/AGENTS.md`);
  });

  it('accepts a nested path', () => {
    assert.equal(safePath('projects/notes.md'), `${WORKSPACE_ROOT}/projects/notes.md`);
  });

  it('accepts the workspace root itself', () => {
    assert.equal(safePath('.'), WORKSPACE_ROOT);
  });

  it('accepts traversal that stays inside the workspace', () => {
    assert.equal(safePath('projects/../people'), `${WORKSPACE_ROOT}/people`);
  });

  it('rejects traversal above the workspace', () => {
    assert.throws(() => safePath('../env'), rejects);
    assert.throws(() => safePath('../../../etc/passwd'), rejects);
  });

  it('rejects an absolute path outside the workspace', () => {
    assert.throws(() => safePath('/etc/passwd'), rejects);
  });

  // The regression this file exists for. A startsWith() prefix check passes
  // every one of these, because each resolves to a sibling directory whose name
  // merely begins with "workspace".
  it('rejects a sibling directory sharing the workspace name prefix', () => {
    assert.throws(() => safePath('../workspace-evil/secret'), rejects);
    assert.throws(() => safePath('../workspace.bak/secret'), rejects);
    assert.throws(() => safePath('../workspace2'), rejects);
  });

  it('rejects the absolute form of a name-prefixed sibling', () => {
    assert.throws(() => safePath(`${WORKSPACE_ROOT}-evil/secret`), rejects);
  });

  it('accepts a file whose name merely starts with dots', () => {
    assert.equal(safePath('..hidden'), `${WORKSPACE_ROOT}/..hidden`);
  });
});
