// =============================================================================
// LadybugDB — Sample Cypher CRUD Queries
//
// Domain: a simple project tracker with People, Projects, and Tasks.
//
// IMPORTANT: LadybugDB requires schema (DDL) to be defined before any data
// can be inserted. This is different from Neo4j, which is schema-optional.
//
// Run these statements in order using the LadybugDB Explorer UI or the
// lbug CLI:
//   docker run -p 8000:8000 --rm ghcr.io/ladybugdb/explorer:latest
// =============================================================================


// =============================================================================
// 0. SCHEMA (DDL) — define node and relationship tables first
// =============================================================================

// Node tables
CREATE NODE TABLE Person (
    id       INT64   PRIMARY KEY,
    name     STRING,
    email    STRING,
    role     STRING
);

CREATE NODE TABLE Project (
    id          INT64   PRIMARY KEY,
    name        STRING,
    description STRING,
    status      STRING   // "active" | "completed" | "archived"
);

CREATE NODE TABLE Task (
    id          INT64   PRIMARY KEY,
    title       STRING,
    priority    STRING,  // "low" | "medium" | "high"
    done        BOOLEAN,
    due_date    DATE
);

// Relationship tables
CREATE REL TABLE WORKS_ON  (FROM Person  TO Project, joined_at DATE);
CREATE REL TABLE ASSIGNED  (FROM Task    TO Person,  assigned_at DATE);
CREATE REL TABLE BELONGS_TO(FROM Task    TO Project);
CREATE REL TABLE MANAGES   (FROM Person  TO Project, since DATE);


// =============================================================================
// 1. CREATE — insert nodes and relationships
// =============================================================================

// --- People ---
CREATE (:Person {id: 1, name: "Alice",   email: "alice@example.com",   role: "engineer"});
CREATE (:Person {id: 2, name: "Bob",     email: "bob@example.com",     role: "designer"});
CREATE (:Person {id: 3, name: "Carol",   email: "carol@example.com",   role: "manager"});

// --- Projects ---
CREATE (:Project {id: 10, name: "LadybugDB GKE Deploy",
                  description: "Deploy LadybugDB on GKE Autopilot with GCS storage",
                  status: "active"});
CREATE (:Project {id: 11, name: "Dashboard UI",
                  description: "Build a monitoring dashboard",
                  status: "active"});

// --- Tasks ---
CREATE (:Task {id: 100, title: "Set up GKE Autopilot cluster",
               priority: "high",   done: false, due_date: date("2026-07-01")});
CREATE (:Task {id: 101, title: "Configure GCS FUSE CSI driver",
               priority: "high",   done: false, due_date: date("2026-07-03")});
CREATE (:Task {id: 102, title: "Design UI wireframes",
               priority: "medium", done: false, due_date: date("2026-07-05")});
CREATE (:Task {id: 103, title: "Write runbook",
               priority: "low",    done: false, due_date: date("2026-07-10")});

// --- Relationships ---
MATCH (alice:Person {id: 1}), (proj:Project {id: 10})
CREATE (alice)-[:WORKS_ON {joined_at: date("2026-06-01")}]->(proj);

MATCH (bob:Person {id: 2}), (proj:Project {id: 11})
CREATE (bob)-[:WORKS_ON {joined_at: date("2026-06-10")}]->(proj);

MATCH (carol:Person {id: 3}), (proj:Project {id: 10})
CREATE (carol)-[:MANAGES {since: date("2026-05-01")}]->(proj);

MATCH (t:Task {id: 100}), (p:Person {id: 1})
CREATE (t)-[:ASSIGNED {assigned_at: date("2026-06-20")}]->(p);

MATCH (t:Task {id: 101}), (p:Person {id: 1})
CREATE (t)-[:ASSIGNED {assigned_at: date("2026-06-20")}]->(p);

MATCH (t:Task {id: 102}), (p:Person {id: 2})
CREATE (t)-[:ASSIGNED {assigned_at: date("2026-06-21")}]->(p);

MATCH (t:Task {id: 100}), (proj:Project {id: 10})
CREATE (t)-[:BELONGS_TO]->(proj);

MATCH (t:Task {id: 101}), (proj:Project {id: 10})
CREATE (t)-[:BELONGS_TO]->(proj);

MATCH (t:Task {id: 102}), (proj:Project {id: 11})
CREATE (t)-[:BELONGS_TO]->(proj);

MATCH (t:Task {id: 103}), (proj:Project {id: 10})
CREATE (t)-[:BELONGS_TO]->(proj);


// =============================================================================
// 2. READ — query data
// =============================================================================

// All people
MATCH (p:Person)
RETURN p.id, p.name, p.email, p.role
ORDER BY p.name;

// All tasks for a specific project, with assignee
MATCH (t:Task)-[:BELONGS_TO]->(proj:Project {id: 10})
OPTIONAL MATCH (t)-[:ASSIGNED]->(assignee:Person)
RETURN t.id, t.title, t.priority, t.done, t.due_date, assignee.name AS assigned_to
ORDER BY t.priority DESC, t.due_date;

// All projects a person is working on
MATCH (p:Person {name: "Alice"})-[:WORKS_ON]->(proj:Project)
RETURN proj.name, proj.status, proj.description;

// High-priority incomplete tasks across all projects
MATCH (t:Task)-[:BELONGS_TO]->(proj:Project)
WHERE t.priority = "high" AND t.done = false
RETURN proj.name AS project, t.title, t.due_date
ORDER BY t.due_date;

// People managing active projects (traversal with filter)
MATCH (mgr:Person)-[:MANAGES]->(proj:Project)
WHERE proj.status = "active"
RETURN mgr.name AS manager, proj.name AS project, proj.description;

// Task count per project
MATCH (t:Task)-[:BELONGS_TO]->(proj:Project)
RETURN proj.name, count(t) AS total_tasks, sum(CASE WHEN t.done THEN 1 ELSE 0 END) AS completed
ORDER BY proj.name;


// =============================================================================
// 3. UPDATE — modify existing nodes and relationships
// =============================================================================

// Mark a task as done
MATCH (t:Task {id: 100})
SET t.done = true;

// Change a person's role
MATCH (p:Person {email: "alice@example.com"})
SET p.role = "senior engineer";

// Update multiple properties at once
MATCH (proj:Project {id: 11})
SET proj.status = "completed",
    proj.description = "Monitoring dashboard — shipped!";

// Remove an optional property by setting it to NULL
// (LadybugDB does not support REMOVE; use SET prop = NULL instead)
MATCH (t:Task {id: 103})
SET t.due_date = NULL;

// Reassign a task to a different person
MATCH (t:Task {id: 102})-[r:ASSIGNED]->(:Person)
DELETE r;
MATCH (t:Task {id: 102}), (carol:Person {id: 3})
CREATE (t)-[:ASSIGNED {assigned_at: date("2026-06-26")}]->(carol);


// =============================================================================
// 4. DELETE — remove nodes and relationships
// =============================================================================

// Delete a specific relationship
MATCH (p:Person {id: 2})-[r:WORKS_ON]->(proj:Project {id: 11})
DELETE r;

// Delete a node (must delete its relationships first)
MATCH (t:Task {id: 103})-[r]-()
DELETE r;
MATCH (t:Task {id: 103})
DELETE t;

// Delete all completed tasks and their relationships (batch delete)
MATCH (t:Task {done: true})-[r]-()
DELETE r;
MATCH (t:Task {done: true})
DELETE t;


// =============================================================================
// 5. MERGE — upsert: create if not exists, match if exists
// =============================================================================

// Upsert a person by email; create if missing, update role if found
MERGE (p:Person {id: 4})
ON CREATE SET p.name = "Dave", p.email = "dave@example.com", p.role = "devops"
ON MATCH  SET p.role = "senior devops";

// Ensure a WORKS_ON relationship exists without duplicating it
MATCH (dave:Person {id: 4}), (proj:Project {id: 10})
MERGE (dave)-[:WORKS_ON {joined_at: date("2026-06-26")}]->(proj);
