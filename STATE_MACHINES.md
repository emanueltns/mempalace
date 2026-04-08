# MemPalace State Machine Diagrams

Visual maps of every major flow in MemPalace.

---

## 1. System Overview

The high-level lifecycle of data through MemPalace.

```mermaid
stateDiagram-v2
    [*] --> Init: mempalace init
    Init --> Palace: config saved

    state "Data Ingestion" as Ingest {
        MineProjects: Mine Projects
        MineConvos: Mine Conversations
    }

    Palace --> Ingest: mempalace mine
    Ingest --> Palace: drawers filed

    state "Recall" as Recall {
        L0: L0 Identity (~50 tokens)
        L1: L1 Critical Facts (~120 tokens)
        L2: L2 Room Recall (on demand)
        L3: L3 Deep Search (on demand)
        L0 --> L1: always loaded
        L1 --> L2: topic comes up
        L2 --> L3: explicit search
    }

    Palace --> Recall: wake-up / search / MCP tool

    state "Auto-Save" as Hooks {
        SaveHook: Save Hook (every 15 msgs)
        PreCompact: PreCompact Hook (before compression)
    }

    Hooks --> Palace: new drawers

    Palace --> Compress: mempalace compress
    Compress --> Palace: AAAK-encoded closets

    Palace --> KnowledgeGraph: kg_add / kg_query
    KnowledgeGraph --> Palace: temporal facts

    Palace --> Sync: cron every 6h
    Sync --> GitHub: git push
```

---

## 2. Initialization / Onboarding

```mermaid
stateDiagram-v2
    [*] --> ScanDir: mempalace init <dir>
    ScanDir --> DetectEntities: read files

    state DetectEntities {
        ScanFiles: Scan file content
        FindPeople: Detect people (capitalized names, pronouns)
        FindProjects: Detect projects (versioned, hyphenated, verbs)
        ScoreConfidence: Score confidence [0-5]
        ScanFiles --> FindPeople
        ScanFiles --> FindProjects
        FindPeople --> ScoreConfidence
        FindProjects --> ScoreConfidence
    }

    DetectEntities --> Confirm

    state Confirm <<choice>>
    Confirm --> AutoAccept: --yes flag
    Confirm --> Interactive: no flag

    Interactive --> UserEdits: user picks enter/edit/add
    UserEdits --> SaveConfig
    AutoAccept --> SaveConfig

    state SaveConfig {
        WriteEntities: Write entities.json
        WriteYaml: Write mempalace.yaml
        DetectRooms: Detect rooms from folder structure
        WriteEntities --> DetectRooms
        WriteYaml --> DetectRooms
    }

    SaveConfig --> [*]: "Next: mempalace mine <dir>"
```

---

## 3. Mining — Project Files

```mermaid
stateDiagram-v2
    [*] --> LoadConfig: mempalace mine <dir>
    LoadConfig --> ScanProject: read mempalace.yaml

    state ScanProject {
        WalkDirs: Walk directory tree
        CheckGitignore: Load .gitignore matchers
        FilterFiles: Filter by extension + gitignore
        WalkDirs --> CheckGitignore
        CheckGitignore --> FilterFiles
    }

    ScanProject --> ProcessFile: for each file

    state ProcessFile {
        [*] --> CheckDuplicate
        CheckDuplicate --> Skip: already mined
        CheckDuplicate --> ReadFile: new file

        ReadFile --> CheckSize
        CheckSize --> Skip: < 50 chars
        CheckSize --> DetectRoom: >= 50 chars

        state DetectRoom {
            MatchPath: 1. Folder path matches room
            MatchFilename: 2. Filename matches room
            MatchKeywords: 3. Content keyword scoring
            Fallback: 4. Fallback to "general"
            MatchPath --> MatchFilename: no match
            MatchFilename --> MatchKeywords: no match
            MatchKeywords --> Fallback: no match
        }

        DetectRoom --> ChunkText

        state ChunkText {
            SlidingWindow: 800 char chunks, 100 overlap
            BreakParagraph: Try break on paragraph
            BreakLine: Try break on newline
            MinCheck: Drop if < 50 chars
        }

        ChunkText --> AddDrawer: for each chunk

        state AddDrawer {
            GenID: drawer_id = md5(file + index)
            DupCheck2: Check existing in ChromaDB
            StoreChroma: Store document + metadata
            GenID --> DupCheck2
            DupCheck2 --> StoreChroma: unique
            DupCheck2 --> SkipChunk: duplicate
        }
    }

    ProcessFile --> ProcessFile: next file
    ProcessFile --> Summary: all files done
    Summary --> [*]: "Done. N drawers filed"

    state Skip {
        [*] --> [*]: return 0
    }
```

---

## 4. Mining — Conversations

```mermaid
stateDiagram-v2
    [*] --> ScanConvos: mempalace mine <dir> --mode convos

    ScanConvos --> NormalizeFormat: for each file

    state NormalizeFormat {
        DetectFormat: Detect format (Claude/ChatGPT/Slack/MD/TXT)
        ConvertStandard: Convert to standard transcript
        DetectFormat --> ConvertStandard
    }

    NormalizeFormat --> ChunkStrategy

    state ChunkStrategy <<choice>>
    ChunkStrategy --> ByExchange: >= 3 lines starting with ">"
    ChunkStrategy --> ByParagraph: < 3 exchange markers

    state ByExchange {
        PairTurns: User turn + AI response = 1 chunk
    }

    state ByParagraph {
        CheckLength: Check paragraph count
        SplitParas: Split on double newline
        BatchLines: Group by 25-line batches (if single long para)
        CheckLength --> SplitParas: multiple paragraphs
        CheckLength --> BatchLines: single paragraph, 20+ lines
    }

    ByExchange --> ExtractMode
    ByParagraph --> ExtractMode

    state ExtractMode <<choice>>
    ExtractMode --> GeneralExtract: --extract general
    ExtractMode --> ExchangeRoute: default

    state GeneralExtract {
        Classify: Classify into memory types
        TypeRoom: room = decisions/preferences/milestones/problems/emotions
    }

    state ExchangeRoute {
        ScoreKeywords: Score: technical/architecture/planning/decisions
        PickRoom: Highest score or "general"
    }

    GeneralExtract --> FileDrawer
    ExchangeRoute --> FileDrawer
    FileDrawer --> [*]: drawers stored
```

---

## 5. Search Flow

```mermaid
stateDiagram-v2
    [*] --> LoadPalace: search "query"

    state LoadPalace {
        ConnectChroma: ChromaDB PersistentClient
        GetCollection: Get "mempalace_drawers"
    }

    LoadPalace --> BuildFilter

    state BuildFilter <<choice>>
    BuildFilter --> NoFilter: no wing, no room
    BuildFilter --> WingFilter: --wing only
    BuildFilter --> RoomFilter: --room only
    BuildFilter --> AndFilter: --wing AND --room

    NoFilter --> QueryChroma
    WingFilter --> QueryChroma
    RoomFilter --> QueryChroma
    AndFilter --> QueryChroma

    state QueryChroma {
        SemanticQuery: col.query(query_texts, where, n_results)
        CalcSimilarity: similarity = 1 - distance
        SortResults: Sort by similarity desc
    }

    QueryChroma --> FormatResults

    state FormatResults <<choice>>
    FormatResults --> CLIDisplay: CLI (mempalace search)
    FormatResults --> ReturnDict: Python API (search_memories)
    FormatResults --> MCPResponse: MCP tool (mempalace_search)

    CLIDisplay --> [*]
    ReturnDict --> [*]
    MCPResponse --> [*]
```

---

## 6. Memory Stack (Wake-Up)

```mermaid
stateDiagram-v2
    [*] --> CreateStack: mempalace wake-up

    state CreateStack {
        state L0 {
            ReadIdentity: Read ~/.mempalace/identity.txt
            RenderL0: ~50 tokens of "who is this AI"
        }

        state L1 {
            FetchBatches: Fetch all drawers (batches of 500)
            ScoreImportance: Score by importance/weight metadata
            TakeTop15: Sort descending, take top 15
            GroupByRoom: Group by room name
            Truncate: Truncate to 3200 chars
            FetchBatches --> ScoreImportance
            ScoreImportance --> TakeTop15
            TakeTop15 --> GroupByRoom
            GroupByRoom --> Truncate
        }
    }

    CreateStack --> WingFilter

    state WingFilter <<choice>>
    WingFilter --> AllWings: no --wing flag
    WingFilter --> FilteredWing: --wing specified

    AllWings --> Output
    FilteredWing --> Output

    Output --> [*]: Return L0 + L1 (~170-900 tokens)
```

---

## 7. Save Hook State Machine

```mermaid
stateDiagram-v2
    [*] --> ReadInput: Stop event fires

    ReadInput --> ParseJSON: read stdin
    ParseJSON --> CheckLoopGuard

    state CheckLoopGuard <<choice>>
    CheckLoopGuard --> AllowStop1: stop_hook_active == true
    CheckLoopGuard --> CountMessages: stop_hook_active == false

    state CountMessages {
        ReadTranscript: Read JSONL transcript
        CountHuman: Count role=user messages
        SkipCommands: Skip command messages
        ReadTranscript --> CountHuman
        CountHuman --> SkipCommands
    }

    CountMessages --> LoadLastSave: read state file
    LoadLastSave --> Calculate: since_last = count - last_save

    state Calculate <<choice>>
    Calculate --> AllowStop2: since_last < 15
    Calculate --> TriggerSave: since_last >= 15

    state TriggerSave {
        UpdateState: Write new last_save count
        OptionalMine: Run mempalace mine (if MEMPAL_DIR set)
        BlockAI: Return decision=block + save instructions
        UpdateState --> OptionalMine
        OptionalMine --> BlockAI
    }

    BlockAI --> AISaves: AI receives block reason
    AISaves --> AIStops: AI saves to palace, tries to stop
    AIStops --> ReadInput: Stop fires again

    note right of AIStops: stop_hook_active=true this time

    AllowStop1 --> [*]: return {}
    AllowStop2 --> [*]: return {}
```

---

## 8. PreCompact Hook State Machine

```mermaid
stateDiagram-v2
    [*] --> Triggered: PreCompact event fires

    Triggered --> ReadInput: read stdin JSON
    ReadInput --> LogEvent: log session_id + timestamp

    LogEvent --> CheckMempalDir

    state CheckMempalDir <<choice>>
    CheckMempalDir --> SyncMine: MEMPAL_DIR is set
    CheckMempalDir --> AlwaysBlock: MEMPAL_DIR empty

    state SyncMine {
        RunMine: mempalace mine (synchronous)
        note: Memories land before compaction
    }

    SyncMine --> AlwaysBlock

    state AlwaysBlock {
        BlockAI: Return decision=block
        note2: reason = "Save ALL topics, decisions, quotes..."
    }

    AlwaysBlock --> AISaves: AI does thorough save
    AISaves --> CompactionProceeds: save complete
    CompactionProceeds --> [*]: context window compressed
```

---

## 9. Knowledge Graph Operations

```mermaid
stateDiagram-v2
    state "Write Operations" as Write {
        [*] --> AddTriple: kg_add(subject, predicate, object)

        state AddTriple {
            NormalizeIDs: Normalize subject/object to IDs
            AutoCreate: Auto-create entities if missing
            CheckExisting: Check for existing active triple
        }

        CheckExisting --> ReturnExisting: same triple exists (idempotent)
        CheckExisting --> InsertTriple: new triple
        InsertTriple --> [*]: triple stored with valid_from

        [*] --> Invalidate: kg_invalidate(subject, predicate, object)

        state Invalidate {
            FindActive: Find triple where valid_to IS NULL
            SetEnded: UPDATE valid_to = ended date
        }

        Invalidate --> [*]: fact marked as expired
    }

    state "Read Operations" as Read {
        [*] --> QueryEntity: kg_query(entity, as_of)

        state QueryEntity {
            ResolveID: Resolve entity name to ID
            TemporalFilter: valid_from <= as_of AND (valid_to IS NULL OR valid_to >= as_of)
            FetchOutgoing: subject = entity
            FetchIncoming: object = entity
        }

        QueryEntity --> Results: facts with current=true/false

        [*] --> Timeline: kg_timeline(entity)

        state Timeline {
            FetchAll: All triples for entity
            SortChronological: ORDER BY valid_from ASC
            Limit100: LIMIT 100
        }

        Timeline --> ChronStory: ordered history
    }
```

---

## 10. Palace Graph Navigation

```mermaid
stateDiagram-v2
    [*] --> BuildGraph: on first query

    state BuildGraph {
        FetchMeta: Fetch all metadata (batches of 1000)
        MapRooms: room_data[room] = {wings, halls, count}
        FindEdges: Rooms appearing in 2+ wings = edges
        FetchMeta --> MapRooms
        MapRooms --> FindEdges
    }

    BuildGraph --> Ready

    state "Traverse (BFS)" as Traverse {
        [*] --> CheckStart: start_room exists?
        CheckStart --> FuzzyMatch: not found
        FuzzyMatch --> [*]: suggest similar rooms

        CheckStart --> InitBFS: found
        InitBFS --> BFSLoop: visited={start}, frontier=[(start,0)]

        state BFSLoop {
            PopNode: Pop (current_room, depth)
            CheckDepth: depth < max_hops?
            FindNeighbors: Rooms sharing a wing with current
            AddUnvisited: Add unvisited to frontier + results
        }

        BFSLoop --> SortResults: frontier empty
        SortResults --> [*]: sorted by (hop_distance, -count), max 50
    }

    state "Find Tunnels" as Tunnels {
        [*] --> ScanRooms: for each room with 2+ wings
        ScanRooms --> MatchWings: check wing_a and wing_b filters
        MatchWings --> CollectTunnels: both match
        CollectTunnels --> [*]: sorted by -count, max 50
    }

    Ready --> Traverse: mempalace_traverse
    Ready --> Tunnels: mempalace_find_tunnels
```

---

## 11. AAAK Compression

```mermaid
stateDiagram-v2
    [*] --> InputText: raw text + metadata

    state "Compression Pipeline" as Compress {
        ExtractEntities: Extract named entities
        ExtractTopics: TF-IDF topic scoring
        ExtractEmotions: Pattern match emotion signals
        ExtractFlags: Detect DECISION/ORIGIN/CORE/PIVOT/TECHNICAL
        ExtractQuotes: Pull key sentences

        ExtractEntities --> Assemble
        ExtractTopics --> Assemble
        ExtractEmotions --> Assemble
        ExtractFlags --> Assemble
        ExtractQuotes --> Assemble
    }

    InputText --> Compress

    state Assemble {
        BuildHeader: FILE_NUM | PRIMARY_ENTITY | DATE | TITLE
        BuildZettels: ZID : ENTITIES | topics | "quote" | WEIGHT | EMOTIONS | FLAGS
        BuildTunnels: T : ZID <-> ZID | label
        BuildArcs: ARC : emotion -> emotion -> emotion
    }

    Assemble --> AAKOutput: compressed AAAK text

    state "Decompression" as Decompress {
        ParseStructure: Parse headers, zettels, arcs
        ExpandEntities: Entity codes -> full names
        ExpandEmotions: Emotion codes -> words
        Reconstruct: Rebuild natural language
    }

    AAKOutput --> Decompress: decompress()
    Decompress --> NaturalText: readable output
```

---

## 12. MCP Server — Tool Dispatch

```mermaid
stateDiagram-v2
    [*] --> ReadStdin: MCP request arrives

    ReadStdin --> ParseJSON
    ParseJSON --> RouteMethod

    state RouteMethod <<choice>>
    RouteMethod --> Initialize: method = "initialize"
    RouteMethod --> ListTools: method = "tools/list"
    RouteMethod --> CallTool: method = "tools/call"

    Initialize --> [*]: return version + capabilities

    ListTools --> [*]: return 19 tool definitions

    state CallTool {
        ParseArgs: Extract tool_name + arguments
        CoerceTypes: Convert JSON types (int, float)
        Dispatch: Call TOOLS[tool_name].handler(**args)
    }

    state Dispatch <<choice>>
    Dispatch --> ReadTools: status / list_wings / list_rooms / taxonomy / search
    Dispatch --> WriteTools: add_drawer / delete_drawer
    Dispatch --> KGTools: kg_query / kg_add / kg_invalidate / kg_timeline
    Dispatch --> NavTools: traverse / find_tunnels / graph_stats
    Dispatch --> DiaryTools: diary_write / diary_read

    state WriteTools {
        DupCheck: Check similarity >= 0.9
        DupCheck --> Reject: duplicate found
        DupCheck --> Store: unique content
    }

    ReadTools --> [*]: return results
    WriteTools --> [*]: return success/reject
    KGTools --> [*]: return facts
    NavTools --> [*]: return graph data
    DiaryTools --> [*]: return entries
```

---

## 13. Auto-Sync to GitHub

```mermaid
stateDiagram-v2
    [*] --> CronTrigger: every 6 hours

    CronTrigger --> GitAddAll: git add -A
    GitAddAll --> CheckChanges: git diff --cached --quiet

    state CheckChanges <<choice>>
    CheckChanges --> Exit: no changes
    CheckChanges --> Commit: changes detected

    Commit --> Push: git commit -m "auto-sync <timestamp>"
    Push --> [*]: git push (LFS handles large files)
    Exit --> [*]: nothing to do
```
