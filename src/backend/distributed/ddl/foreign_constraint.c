/*-------------------------------------------------------------------------
 *
 * foreign_constraint.c
 *
 * This file contains functions to create, alter and drop foreign
 * constraints on distributed tables.
 *
 * Copyright (c) 2018, Citus Data, Inc.
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/namespace.h"
#include "catalog/pg_constraint.h"
#include "catalog/pg_constraint_fn.h"
#include "catalog/pg_type.h"
#include "distributed/colocation_utils.h"
#include "distributed/foreign_constraint.h"
#include "distributed/master_protocol.h"
#include "distributed/multi_join_order.h"
#include "nodes/pg_list.h"
#include "utils/fmgroids.h"
#include "utils/rel.h"
#include "utils/relcache.h"
#include "utils/ruleutils.h"
#include "utils/syscache.h"


typedef struct FRelNodeId
{
	Oid relationId;
}FRelNodeId;


typedef struct FRelNode
{
	FRelNodeId relationId;
	uint32 index;
	List *adjacencyList;
}FRelNode;


static void SetFRelNodeParameters(FRelGraph *frelGraph, FRelNode *frelNode,
								  uint32 *currentIndex, Oid relationId);
static void ClosureUtil(FRelGraph *frelGraph, uint32 sourceId, uint32 vertexId);
static void CreateTransitiveClosure(FRelGraph *frelGraph);


/*
 * CreateForeignKeyRelationGraph creates the foreign key relation graph using
 * foreign constraint provided by pg_constraint metadata table.
 */
FRelGraph *
CreateForeignKeyRelationGraph()
{
	SysScanDesc fkeyScan;
	HeapTuple tuple;
	HASHCTL info;
	uint32 hashFlags = 0;
	Relation fkeyRel;
	FRelGraph *frelGraph = (FRelGraph *) palloc(sizeof(FRelGraph));
	uint32 curIndex = 0;

	/* create (oid) -> [FRelNode] hash */
	memset(&info, 0, sizeof(info));
	info.keysize = sizeof(FRelNodeId);
	info.entrysize = sizeof(FRelNode);
	info.hash = oid_hash;
	info.hcxt = CurrentMemoryContext;
	hashFlags = (HASH_ELEM | HASH_FUNCTION | HASH_CONTEXT);

	frelGraph->nodeMap = hash_create("foreign key relation map (oid)",
									 64 * 32, &info, hashFlags);

	fkeyRel = heap_open(ConstraintRelationId, AccessShareLock);
	fkeyScan = systable_beginscan(fkeyRel, ConstraintRelidIndexId, true,
								  NULL, 0, NULL);

	while (HeapTupleIsValid(tuple = systable_getnext(fkeyScan)))
	{
		Form_pg_constraint con = (Form_pg_constraint) GETSTRUCT(tuple);
		bool referringFound = false;
		bool referredFound = false;
		FRelNode *referringNode = NULL;
		FRelNode *referredNode = NULL;
		FRelNodeId *referringNodeId = NULL;
		FRelNodeId *referredNodeId = NULL;

		/* Not a foreign key */
		if (con->contype != CONSTRAINT_FOREIGN)
		{
			continue;
		}

		referringNodeId = (FRelNodeId *) palloc(sizeof(FRelNodeId));
		referredNodeId = (FRelNodeId *) palloc(sizeof(FRelNodeId));
		referringNodeId->relationId = con->conrelid;
		referredNodeId->relationId = con->confrelid;

		referringNode = (FRelNode *) hash_search(frelGraph->nodeMap, referringNodeId,
												 HASH_ENTER, &referringFound);
		referredNode = (FRelNode *) hash_search(frelGraph->nodeMap, referredNodeId,
												HASH_ENTER, &referredFound);

		/*
		 * If we found a node in the graph we only need to add referred node to
		 * the adjacency  list of that node.
		 */
		if (referringFound)
		{
			/*
			 * If referred node is already in the adjacency list of referred node, do nothing.
			 */
			if (referringNode->adjacencyList == NIL || !list_member(
					referringNode->adjacencyList, referredNode))
			{
				/*
				 * If referred node also exists, add it to the adjacency list
				 * and continue.
				 */
				if (referredFound)
				{
					referringNode->adjacencyList = lappend(referringNode->adjacencyList,
														   referredNode);
				}
				else
				{
					/*
					 * We need to create the node and also add the relationId to
					 * index to oid mapping. Then, add it to the adjacency list
					 * of referring node.
					 */
					SetFRelNodeParameters(frelGraph, referredNode, &curIndex,
										  con->confrelid);
					referringNode->adjacencyList = lappend(referringNode->adjacencyList,
														   referredNode);
				}
			}
			else
			{
				continue;
			}
		}
		else
		{
			/*
			 * If referring node is not exist in the graph, set its remaining parameters.
			 */
			SetFRelNodeParameters(frelGraph, referringNode, &curIndex, con->conrelid);

			if (referredFound)
			{
				referringNode->adjacencyList = lappend(referringNode->adjacencyList,
													   referredNode);
			}
			else
			{
				SetFRelNodeParameters(frelGraph, referredNode, &curIndex, con->confrelid);
				referringNode->adjacencyList = lappend(referringNode->adjacencyList,
													   referredNode);
			}
		}
	}

	/* initialize transitivity matrix */
	frelGraph->nodeCount = curIndex;
	frelGraph->transitivityMatrix = (bool **) palloc(frelGraph->nodeCount *
													 sizeof(bool *));

	curIndex = 0;
	while (curIndex < frelGraph->nodeCount)
	{
		frelGraph->transitivityMatrix[curIndex] = (bool *) palloc(frelGraph->nodeCount *
																  sizeof(bool));
		memset(frelGraph->transitivityMatrix[curIndex], false, frelGraph->nodeCount *
			   sizeof(bool));
		curIndex += 1;
	}

	/*
	 * Transitivity matrix will be used to find affected and affecting relations
	 * for foreign key relation graph.
	 */
	CreateTransitiveClosure(frelGraph);

	systable_endscan(fkeyScan);
	heap_close(fkeyRel, AccessShareLock);

	return frelGraph;
}


/*
 * SetFRelNodeParameters sets the parameters of given node to make it usable
 * for FRelGraph.
 */
static void
SetFRelNodeParameters(FRelGraph *frelGraph, FRelNode *frelNode, uint32 *currentIndex, Oid
					  relationId)
{
	frelNode->adjacencyList = NIL;
	frelNode->index = *currentIndex;

	if (*currentIndex == 0)
	{
		frelGraph->indexToOid = palloc(sizeof(uint32));
	}
	else
	{
		frelGraph->indexToOid = repalloc(frelGraph->indexToOid, (*currentIndex + 1) *
										 sizeof(uint32));
	}

	frelGraph->indexToOid[*currentIndex] = relationId;
	*currentIndex += 1;
}


/*
 * CreateTransitiveClosure creates the transitive closure matrix for the given
 * graph.
 */
static void
CreateTransitiveClosure(FRelGraph *frelGraph)
{
	uint32 tableCounter = 0;

	while (tableCounter < frelGraph->nodeCount)
	{
		ClosureUtil(frelGraph, tableCounter, tableCounter);
		tableCounter += 1;
	}

	/*
	 * Print it in the debug mode.
	 */
	tableCounter = 0;
	while (tableCounter < frelGraph->nodeCount)
	{
		int innerTableCounter = 0;
		while (innerTableCounter < frelGraph->nodeCount)
		{
			if (frelGraph->transitivityMatrix[tableCounter][innerTableCounter])
			{
				Oid firstRelationId = frelGraph->indexToOid[tableCounter];
				Oid secondRelationId = frelGraph->indexToOid[innerTableCounter];

				elog(DEBUG1, "Path from relation %d to relation %d", firstRelationId,
					 secondRelationId);
			}
			innerTableCounter += 1;
		}
		tableCounter += 1;
	}
}


/*
 * ClosureUtil is a utility function for recursively filling transitivity vector
 * for a given source id.
 */
static void
ClosureUtil(FRelGraph *frelGraph, uint32 sourceId, uint32 vertexId)
{
	FRelNodeId *currentNodeId = (FRelNodeId *) palloc(sizeof(FRelNodeId));
	FRelNode *referringNode = NULL;
	bool isFound = false;
	List *adjacencyList = NIL;
	ListCell *nodeCell = NULL;

	/* There is a path from node to itself */
	frelGraph->transitivityMatrix[sourceId][vertexId] = true;
	currentNodeId->relationId = frelGraph->indexToOid[vertexId];

	referringNode = (FRelNode *) hash_search(frelGraph->nodeMap, currentNodeId, HASH_FIND,
											 &isFound);
	Assert(isFound);

	adjacencyList = referringNode->adjacencyList;

	foreach(nodeCell, adjacencyList)
	{
		FRelNode *currentNeighbourNode = (FRelNode *) lfirst(nodeCell);
		uint32 currentNeighbourIndex = currentNeighbourNode->index;

		if (frelGraph->transitivityMatrix[sourceId][currentNeighbourIndex] == false)
		{
			ClosureUtil(frelGraph, sourceId, currentNeighbourIndex);
		}
	}
}


/*
 * GetForeignKeyRelation returns the list of oids affected or affecting given
 * relation id.
 */
List *
GetForeignKeyRelation(FRelGraph *frelGraph, Oid relationId, bool isAffecting)
{
	List *foreignKeyList = NIL;
	bool isFound = false;
	FRelNodeId *relationNodeId = (FRelNodeId *) palloc(sizeof(FRelNodeId));
	FRelNode *relationNode = NULL;
	uint32 relationIndex = -1;
	relationNodeId->relationId = relationId;

	relationNode = (FRelNode *) hash_search(frelGraph->nodeMap, relationNodeId,
											HASH_ENTER, &isFound);

	if (!isFound)
	{
		return NIL;
	}
	else
	{
		relationIndex = relationNode->index;
		if (isAffecting)
		{
			uint32 tableCounter = 0;

			while (tableCounter < frelGraph->nodeCount)
			{
				if (frelGraph->transitivityMatrix[relationIndex][tableCounter])
				{
					Oid referredTableOid = frelGraph->indexToOid[tableCounter];
					foreignKeyList = lappend_oid(foreignKeyList, referredTableOid);
				}

				tableCounter += 1;
			}
		}
		else
		{
			uint32 tableCounter = 0;

			while (tableCounter < frelGraph->nodeCount)
			{
				if (frelGraph->transitivityMatrix[tableCounter][relationIndex])
				{
					Oid referringTableOid = frelGraph->indexToOid[tableCounter];
					foreignKeyList = lappend_oid(foreignKeyList, referringTableOid);
				}

				tableCounter += 1;
			}
		}
	}

	return foreignKeyList;
}


/*
 * ErrorIfUnsupportedForeignConstraint runs checks related to foreign constraints and
 * errors out if it is not possible to create one of the foreign constraint in distributed
 * environment.
 *
 * To support foreign constraints, we require that;
 * - Referencing and referenced tables are hash distributed.
 * - Referencing and referenced tables are co-located.
 * - Foreign constraint is defined over distribution column.
 * - ON DELETE/UPDATE SET NULL, ON DELETE/UPDATE SET DEFAULT and ON UPDATE CASCADE options
 *   are not used.
 * - Replication factors of referencing and referenced table are 1.
 */
void
ErrorIfUnsupportedForeignConstraint(Relation relation, char distributionMethod,
									Var *distributionColumn, uint32 colocationId)
{
	Relation pgConstraint = NULL;
	SysScanDesc scanDescriptor = NULL;
	ScanKeyData scanKey[1];
	int scanKeyCount = 1;
	HeapTuple heapTuple = NULL;

	Oid referencingTableId = relation->rd_id;
	Oid referencedTableId = InvalidOid;
	uint32 referencedTableColocationId = INVALID_COLOCATION_ID;
	Var *referencedTablePartitionColumn = NULL;

	Datum referencingColumnsDatum;
	Datum *referencingColumnArray;
	int referencingColumnCount = 0;
	Datum referencedColumnsDatum;
	Datum *referencedColumnArray;
	int referencedColumnCount = 0;
	bool isNull = false;
	int attrIdx = 0;
	bool foreignConstraintOnPartitionColumn = false;
	bool selfReferencingTable = false;

	pgConstraint = heap_open(ConstraintRelationId, AccessShareLock);
	ScanKeyInit(&scanKey[0], Anum_pg_constraint_conrelid, BTEqualStrategyNumber, F_OIDEQ,
				relation->rd_id);
	scanDescriptor = systable_beginscan(pgConstraint, ConstraintRelidIndexId, true, NULL,
										scanKeyCount, scanKey);

	heapTuple = systable_getnext(scanDescriptor);
	while (HeapTupleIsValid(heapTuple))
	{
		Form_pg_constraint constraintForm = (Form_pg_constraint) GETSTRUCT(heapTuple);
		bool singleReplicatedTable = true;

		if (constraintForm->contype != CONSTRAINT_FOREIGN)
		{
			heapTuple = systable_getnext(scanDescriptor);
			continue;
		}

		referencedTableId = constraintForm->confrelid;
		selfReferencingTable = referencingTableId == referencedTableId;

		/*
		 * We do not support foreign keys for reference tables. Here we skip the second
		 * part of check if the table is a self referencing table because;
		 * - PartitionMethod only works for distributed tables and this table may not be
		 * distributed yet.
		 * - Since referencing and referenced tables are same, it is OK to not checking
		 * distribution method twice.
		 */
		if (distributionMethod == DISTRIBUTE_BY_NONE ||
			(!selfReferencingTable &&
			 PartitionMethod(referencedTableId) == DISTRIBUTE_BY_NONE))
		{
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("cannot create foreign key constraint from or to "
								   "reference tables")));
		}

		/*
		 * ON DELETE SET NULL and ON DELETE SET DEFAULT is not supported. Because we do
		 * not want to set partition column to NULL or default value.
		 */
		if (constraintForm->confdeltype == FKCONSTR_ACTION_SETNULL ||
			constraintForm->confdeltype == FKCONSTR_ACTION_SETDEFAULT)
		{
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("cannot create foreign key constraint"),
							errdetail("SET NULL or SET DEFAULT is not supported"
									  " in ON DELETE operation.")));
		}

		/*
		 * ON UPDATE SET NULL, ON UPDATE SET DEFAULT and UPDATE CASCADE is not supported.
		 * Because we do not want to set partition column to NULL or default value. Also
		 * cascading update operation would require re-partitioning. Updating partition
		 * column value is not allowed anyway even outside of foreign key concept.
		 */
		if (constraintForm->confupdtype == FKCONSTR_ACTION_SETNULL ||
			constraintForm->confupdtype == FKCONSTR_ACTION_SETDEFAULT ||
			constraintForm->confupdtype == FKCONSTR_ACTION_CASCADE)
		{
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("cannot create foreign key constraint"),
							errdetail("SET NULL, SET DEFAULT or CASCADE is not"
									  " supported in ON UPDATE operation.")));
		}

		/*
		 * Some checks are not meaningful if foreign key references the table itself.
		 * Therefore we will skip those checks.
		 */
		if (!selfReferencingTable)
		{
			if (!IsDistributedTable(referencedTableId))
			{
				ereport(ERROR, (errcode(ERRCODE_INVALID_TABLE_DEFINITION),
								errmsg("cannot create foreign key constraint"),
								errdetail("Referenced table must be a distributed "
										  "table.")));
			}

			/* to enforce foreign constraints, tables must be co-located */
			referencedTableColocationId = TableColocationId(referencedTableId);
			if (colocationId == INVALID_COLOCATION_ID ||
				colocationId != referencedTableColocationId)
			{
				ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
								errmsg("cannot create foreign key constraint"),
								errdetail("Foreign key constraint can only be created"
										  " on co-located tables.")));
			}

			/*
			 * Partition column must exist in both referencing and referenced side of the
			 * foreign key constraint. They also must be in same ordinal.
			 */
			referencedTablePartitionColumn = DistPartitionKey(referencedTableId);
		}
		else
		{
			/*
			 * Partition column must exist in both referencing and referenced side of the
			 * foreign key constraint. They also must be in same ordinal.
			 */
			referencedTablePartitionColumn = distributionColumn;
		}

		/*
		 * Column attributes are not available in Form_pg_constraint, therefore we need
		 * to find them in the system catalog. After finding them, we iterate over column
		 * attributes together because partition column must be at the same place in both
		 * referencing and referenced side of the foreign key constraint
		 */
		referencingColumnsDatum = SysCacheGetAttr(CONSTROID, heapTuple,
												  Anum_pg_constraint_conkey, &isNull);
		referencedColumnsDatum = SysCacheGetAttr(CONSTROID, heapTuple,
												 Anum_pg_constraint_confkey, &isNull);

		deconstruct_array(DatumGetArrayTypeP(referencingColumnsDatum), INT2OID, 2, true,
						  's', &referencingColumnArray, NULL, &referencingColumnCount);
		deconstruct_array(DatumGetArrayTypeP(referencedColumnsDatum), INT2OID, 2, true,
						  's', &referencedColumnArray, NULL, &referencedColumnCount);

		Assert(referencingColumnCount == referencedColumnCount);

		for (attrIdx = 0; attrIdx < referencingColumnCount; ++attrIdx)
		{
			AttrNumber referencingAttrNo = DatumGetInt16(referencingColumnArray[attrIdx]);
			AttrNumber referencedAttrNo = DatumGetInt16(referencedColumnArray[attrIdx]);

			if (distributionColumn->varattno == referencingAttrNo &&
				referencedTablePartitionColumn->varattno == referencedAttrNo)
			{
				foreignConstraintOnPartitionColumn = true;
			}
		}

		if (!foreignConstraintOnPartitionColumn)
		{
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("cannot create foreign key constraint"),
							errdetail("Partition column must exist both "
									  "referencing and referenced side of the "
									  "foreign constraint statement and it must "
									  "be in the same ordinal in both sides.")));
		}

		/*
		 * We do not allow to create foreign constraints if shard replication factor is
		 * greater than 1. Because in our current design, multiple replicas may cause
		 * locking problems and inconsistent shard contents. We don't check the referenced
		 * table, since referenced and referencing tables should be co-located and
		 * colocation check has been done above.
		 */
		if (IsDistributedTable(referencingTableId))
		{
			/* check whether ALTER TABLE command is applied over single replicated table */
			if (!SingleReplicatedTable(referencingTableId))
			{
				singleReplicatedTable = false;
			}
		}
		else
		{
			/* check whether creating single replicated table with foreign constraint */
			if (ShardReplicationFactor > 1)
			{
				singleReplicatedTable = false;
			}
		}

		if (!singleReplicatedTable)
		{
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("cannot create foreign key constraint"),
							errdetail("Citus Community Edition currently supports "
									  "foreign key constraints only for "
									  "\"citus.shard_replication_factor = 1\"."),
							errhint("Please change \"citus.shard_replication_factor to "
									"1\". To learn more about using foreign keys with "
									"other replication factors, please contact us at "
									"https://citusdata.com/about/contact_us.")));
		}

		heapTuple = systable_getnext(scanDescriptor);
	}

	/* clean up scan and close system catalog */
	systable_endscan(scanDescriptor);
	heap_close(pgConstraint, AccessShareLock);
}


/*
 * GetTableForeignConstraints takes in a relationId, and returns the list of foreign
 * constraint commands needed to reconstruct foreign constraints of that table.
 */
List *
GetTableForeignConstraintCommands(Oid relationId)
{
	List *tableForeignConstraints = NIL;

	Relation pgConstraint = NULL;
	SysScanDesc scanDescriptor = NULL;
	ScanKeyData scanKey[1];
	int scanKeyCount = 1;
	HeapTuple heapTuple = NULL;

	/*
	 * Set search_path to NIL so that all objects outside of pg_catalog will be
	 * schema-prefixed. pg_catalog will be added automatically when we call
	 * PushOverrideSearchPath(), since we set addCatalog to true;
	 */
	OverrideSearchPath *overridePath = GetOverrideSearchPath(CurrentMemoryContext);
	overridePath->schemas = NIL;
	overridePath->addCatalog = true;
	PushOverrideSearchPath(overridePath);

	/* open system catalog and scan all constraints that belong to this table */
	pgConstraint = heap_open(ConstraintRelationId, AccessShareLock);
	ScanKeyInit(&scanKey[0], Anum_pg_constraint_conrelid, BTEqualStrategyNumber, F_OIDEQ,
				relationId);
	scanDescriptor = systable_beginscan(pgConstraint, ConstraintRelidIndexId, true, NULL,
										scanKeyCount, scanKey);

	heapTuple = systable_getnext(scanDescriptor);
	while (HeapTupleIsValid(heapTuple))
	{
		Form_pg_constraint constraintForm = (Form_pg_constraint) GETSTRUCT(heapTuple);

		if (constraintForm->contype == CONSTRAINT_FOREIGN)
		{
			Oid constraintId = get_relation_constraint_oid(relationId,
														   constraintForm->conname.data,
														   true);
			char *statementDef = pg_get_constraintdef_command(constraintId);

			tableForeignConstraints = lappend(tableForeignConstraints, statementDef);
		}

		heapTuple = systable_getnext(scanDescriptor);
	}

	/* clean up scan and close system catalog */
	systable_endscan(scanDescriptor);
	heap_close(pgConstraint, AccessShareLock);

	/* revert back to original search_path */
	PopOverrideSearchPath();

	return tableForeignConstraints;
}


/*
 * TableReferenced function checks whether given table is referenced by another table
 * via foreign constraints. If it is referenced, this function returns true. To check
 * that, this function searches given relation at pg_constraints system catalog. However
 * since there is no index for the column we searched, this function performs sequential
 * search, therefore call this function with caution.
 */
bool
TableReferenced(Oid relationId)
{
	Relation pgConstraint = NULL;
	HeapTuple heapTuple = NULL;
	SysScanDesc scanDescriptor = NULL;
	ScanKeyData scanKey[1];
	int scanKeyCount = 1;
	Oid scanIndexId = InvalidOid;
	bool useIndex = false;

	pgConstraint = heap_open(ConstraintRelationId, AccessShareLock);

	ScanKeyInit(&scanKey[0], Anum_pg_constraint_confrelid, BTEqualStrategyNumber, F_OIDEQ,
				relationId);
	scanDescriptor = systable_beginscan(pgConstraint, scanIndexId, useIndex, NULL,
										scanKeyCount, scanKey);

	heapTuple = systable_getnext(scanDescriptor);
	while (HeapTupleIsValid(heapTuple))
	{
		Form_pg_constraint constraintForm = (Form_pg_constraint) GETSTRUCT(heapTuple);

		if (constraintForm->contype == CONSTRAINT_FOREIGN)
		{
			systable_endscan(scanDescriptor);
			heap_close(pgConstraint, NoLock);

			return true;
		}

		heapTuple = systable_getnext(scanDescriptor);
	}

	systable_endscan(scanDescriptor);
	heap_close(pgConstraint, NoLock);

	return false;
}
