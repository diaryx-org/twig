//! Read-side helpers over an [`Ast`]: child iteration, paths, subtrees.

use crate::ast::{Ast, Kind, Node, NodeId};

pub struct Children<'a> {
    ast: &'a Ast,
    next: Option<NodeId>,
}

impl<'a> Iterator for Children<'a> {
    type Item = &'a Node;
    fn next(&mut self) -> Option<&'a Node> {
        let id = self.next?;
        let node = &self.ast.nodes[id as usize];
        self.next = node.next_sibling;
        Some(node)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct TableRow {
    pub id: NodeId,
    pub head: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub struct PathOutOfBounds;

impl Ast {
    pub fn children(&self, id: NodeId) -> Children<'_> {
        Children { ast: self, next: self.nodes[id as usize].first_child }
    }

    pub fn child_ids(&self, id: NodeId) -> Vec<NodeId> {
        self.children(id).map(|n| n.id).collect()
    }

    /// The rows of a table, skipping its caption and column axis.
    pub fn table_rows(&self, table: NodeId) -> impl Iterator<Item = TableRow> + '_ {
        self.children(table).filter_map(|n| match n.kind {
            Kind::Row { head } => Some(TableRow { id: n.id, head }),
            _ => None,
        })
    }

    pub fn id_by_path(&self, path: &[usize]) -> Result<NodeId, PathOutOfBounds> {
        let mut id = self.root;
        for &idx in path {
            let mut child = self.nodes[id as usize].first_child.ok_or(PathOutOfBounds)?;
            for _ in 0..idx {
                child = self.nodes[child as usize].next_sibling.ok_or(PathOutOfBounds)?;
            }
            id = child;
        }
        Ok(id)
    }

    /// The index path from the root to `target`, or `None` when unreachable.
    pub fn path_of(&self, target: NodeId) -> Option<Vec<usize>> {
        fn find(ast: &Ast, id: NodeId, target: NodeId, acc: &mut Vec<usize>) -> bool {
            if id == target {
                return true;
            }
            let mut idx = 0;
            let mut c = ast.nodes[id as usize].first_child;
            while let Some(cid) = c {
                acc.push(idx);
                if find(ast, cid, target, acc) {
                    return true;
                }
                acc.pop();
                c = ast.nodes[cid as usize].next_sibling;
                idx += 1;
            }
            false
        }
        let mut acc = Vec::new();
        if find(self, self.root, target, &mut acc) { Some(acc) } else { None }
    }

    /// `root` first, then every descendant in breadth-first order.
    pub fn subtree_ids(&self, root: NodeId) -> Vec<NodeId> {
        let mut order = vec![root];
        let mut i = 0;
        while i < order.len() {
            let mut c = self.nodes[order[i] as usize].first_child;
            while let Some(cid) = c {
                order.push(cid);
                c = self.nodes[cid as usize].next_sibling;
            }
            i += 1;
        }
        order
    }

    /// Every node with no parent except the root — the detached definitions.
    pub fn definition_roots(&self) -> Vec<NodeId> {
        let mut parented = vec![false; self.nodes.len()];
        for node in &self.nodes {
            let mut c = node.first_child;
            while let Some(cid) = c {
                parented[cid as usize] = true;
                c = self.nodes[cid as usize].next_sibling;
            }
        }
        (0..self.nodes.len() as NodeId).filter(|&id| !parented[id as usize] && id != self.root).collect()
    }

    /// `parents[id]` for every node.
    pub fn parents(&self) -> Vec<Option<NodeId>> {
        let mut parents = vec![None; self.nodes.len()];
        for n in &self.nodes {
            let mut c = n.first_child;
            while let Some(id) = c {
                parents[id as usize] = Some(n.id);
                c = self.nodes[id as usize].next_sibling;
            }
        }
        parents
    }

    /// The parent of `id`, found by a scan (O(n)).
    pub fn parent_of(&self, id: NodeId) -> Option<NodeId> {
        for n in &self.nodes {
            let mut c = n.first_child;
            while let Some(cid) = c {
                if cid == id {
                    return Some(n.id);
                }
                c = self.nodes[cid as usize].next_sibling;
            }
        }
        None
    }
}
