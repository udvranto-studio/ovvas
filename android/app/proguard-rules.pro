# Room creates each database class (e.g. WorkManager's WorkDatabase_Impl) with
# its no-argument constructor, found by name at runtime. play-services-ads
# pulls in WorkManager 2.7 with Room 2.2.5, whose rule keeps only the class
# name. R8 full mode then removes the constructor and the app crashes at
# launch ("Failed to create an instance of androidx.work.impl.WorkDatabase").
-keep class * extends androidx.room.RoomDatabase { <init>(); }
