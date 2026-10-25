'use strict';

const crypto = require('crypto');

// The object id git gives a blob, which the branch tree reports for each path.
const blobOid = (bytes) =>
  crypto
    .createHash('sha1')
    .update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`), bytes]))
    .digest('hex');

/**
 * Commits the listed paths to `branch` in one createCommitOnBranch call, anchored to the head
 * read first, so a branch that moves in between fails the commit instead of losing the change.
 * Returns `{ changed, commit }`.
 */
module.exports = async function apiCommit({ github, readFile, exists, repository, branch, paths, message }) {
  const [owner, name] = repository.split('/');
  const files = paths.split('\n').map((p) => p.trim()).filter((p) => p.length > 0);
  if (files.length === 0) throw new Error('paths lists no file');
  const lines = message.split('\n');
  const headline = lines[0].trim();
  if (headline.length === 0) throw new Error('message has an empty headline');
  const body = lines.slice(1).join('\n').trim();

  const aliases = files.map((_, i) => `f${i}: file(path: $p${i}) { oid }`).join('\n');
  const vars = files.map((_, i) => `$p${i}: String!`).join(', ');
  // A path absent at the head comes back as null data plus a NOT_FOUND error, and the client throws
  // on any error; those lookups are expected, every other error is not.
  const lookup = async (query, variables) => {
    try {
      return await github.graphql(query, variables);
    } catch (e) {
      const expected = e.data && Array.isArray(e.errors) && e.errors.length > 0 &&
        e.errors.every((x) => x.type === 'NOT_FOUND' && /^f\d+$/.test(String(x.path?.[3])));
      if (expected) return e.data;
      throw e;
    }
  };
  const { repository: repo } = await lookup(
    `query($owner: String!, $name: String!, $ref: String!${vars ? `, ${vars}` : ''}) {
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) { target { ... on Commit { oid ${aliases} } } }
      }
    }`,
    { owner, name, ref: `refs/heads/${branch}`, ...Object.fromEntries(files.map((p, i) => [`p${i}`, p])) },
  );
  if (!repo.ref) throw new Error(`${repository} has no branch ${branch}`);
  const head = repo.ref.target;

  const additions = [];
  const deletions = [];
  files.forEach((path, i) => {
    const remote = head[`f${i}`]?.oid ?? null;
    if (exists(path)) {
      const bytes = readFile(path);
      if (blobOid(bytes) !== remote) additions.push({ path, contents: bytes.toString('base64') });
    } else if (remote !== null) {
      deletions.push({ path });
    }
  });
  if (additions.length === 0 && deletions.length === 0) return { changed: false, commit: null };

  const { createCommitOnBranch } = await github.graphql(
    `mutation($input: CreateCommitOnBranchInput!) {
      createCommitOnBranch(input: $input) { commit { oid } }
    }`,
    {
      input: {
        branch: { repositoryNameWithOwner: repository, branchName: branch },
        expectedHeadOid: head.oid,
        message: body ? { headline, body } : { headline },
        fileChanges: { additions, deletions },
      },
    },
  );
  return { changed: true, commit: createCommitOnBranch.commit.oid };
};

module.exports.blobOid = blobOid;
