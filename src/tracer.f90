
module tracer 

    use tracer_precision
    use tracer_interp 
    use bspline_module, only : bspline_3d 
    use ncio   
    use nml 

    implicit none 

    
    type tracer_par_class 
        integer :: n, n_active, n_max_dep, id_max 
        logical :: is_sigma                     ! Is the defined z-axis in sigma coords
        real(prec) :: time_now, time_old, dt
        real(prec) :: time_dep, time_write 
        real(prec) :: thk_min                   ! Minimum thickness of tracer (m)
        real(prec) :: H_min                     ! Minimum ice thickness to track (m)
        real(prec) :: depth_max                 ! Maximum depth of tracer (fraction)
        real(prec) :: U_max                     ! Maximum horizontal velocity of tracer to track (m/a)
        real(prec) :: H_min_dep                 ! Minimum ice thickness for tracer deposition (m)
        real(prec) :: alpha                     ! Slope of probability function
        character(len=56) :: dist               ! Distribution for generating prob. function
        real(prec) :: dens_z_lim                ! Distance from surface to count density
        integer    :: dens_max                  ! Max allowed density of particles at surface
        
        character(len=56) :: interp_method 
    end type 

    type tracer_state_class 
        integer,    allocatable :: active(:), id(:)
        real(prec), allocatable :: x(:), y(:), z(:), sigma(:)
        real(prec), allocatable :: dpth(:), z_srf(:)
        real(prec), allocatable :: ux(:), uy(:), uz(:)
        real(prec), allocatable :: thk(:)            ! Tracer thickness (for compression)
        real(prec), allocatable :: T(:)              ! Current temperature of the tracer (for borehole comparison, internal melting...)
        real(prec), allocatable :: H(:)

    end type 

    type tracer_stats_class
        real(prec), allocatable :: x(:), y(:)
        real(prec), allocatable :: depth_norm(:)
        real(prec), allocatable :: age_iso(:) 
        real(prec), allocatable :: depth_iso(:,:,:)
        real(prec), allocatable :: depth_iso_err(:,:,:)
        real(prec), allocatable :: ice_age(:,:,:)
        real(prec), allocatable :: ice_age_err(:,:,:)
        integer,    allocatable :: density(:,:,:)
        integer,    allocatable :: density_iso(:,:,:)
        

    end type

    type tracer_dep_class 
        ! Standard deposition information (time and place)
        real(prec), allocatable :: time(:) 
        real(prec), allocatable :: H(:) 
        real(prec), allocatable :: x(:), y(:), z(:)
        real(prec), allocatable :: lon(:), lat(:) 

        ! Additional tracer deposition information (climate, isotopes, etc)
        real(prec), allocatable :: t2m(:,:)     ! 4 seasons 
        real(prec), allocatable :: pr(:,:)      ! 4 seasons 
        real(prec), allocatable :: t2m_prann(:) ! Precip-weighted temp

!         real(prec), allocatable :: d18O(:)
!         real(prec), allocatable :: dD(:)

    end type 

    type tracer_class 
        type(tracer_par_class)   :: par 
        type(tracer_state_class) :: now 
        type(tracer_dep_class)   :: dep
        type(tracer_stats_class) :: stats 

    end type 

    type(lin3_interp_par_type) :: par_lin 
    type(bspline_3d)           :: bspline3d_ux, bspline3d_uy, bspline3d_uz 

    private 

    ! For tracer2D module
    public :: tracer_par_class
    public :: tracer_state_class
    public :: tracer_dep_class
    public :: tracer_stats_class

    ! General public 
    public :: tracer_class 
    public :: tracer_init 
    public :: tracer_update 
    public :: tracer_end 
    public :: tracer_write_init, tracer_write 
    public :: tracer_write_stats 

contains 

    subroutine tracer_init(trc,filename,time,x,y,z,is_sigma)

        implicit none 

        type(tracer_class),   intent(OUT) :: trc 
        character(len=*),     intent(IN)  :: filename 
        real(prec), intent(IN) :: x(:), y(:), z(:)
        logical,    intent(IN) :: is_sigma  
        real(4) :: time 

        ! Local variables 
        integer :: i 

        ! Load the parameters
        call tracer_par_load(trc%par,filename,is_sigma)

        ! Allocate the state variables 
        call tracer_allocate(trc%now,trc%dep,n=trc%par%n)
        call tracer_allocate_stats(trc%stats,x,y)

        ! ===== Initialize stats depth axes ===============

        trc%stats%age_iso = [11.7,29.0,57.0,115.0,130.0]

        do i = 1, size(trc%stats%depth_norm)
            trc%stats%depth_norm(i) = 0.04*real(i)
        end do 

        ! =================================================

        ! Initialize state 
        trc%now%active    = 0 

        trc%now%id        = mv 
        trc%now%x         = mv 
        trc%now%y         = mv 
        trc%now%z         = mv 
        trc%now%sigma     = mv 
        trc%now%z_srf     = mv 
        trc%now%dpth      = mv 
        trc%now%ux        = mv 
        trc%now%uy        = mv 
        trc%now%uz        = mv 
        trc%now%thk       = mv 
        trc%now%T         = mv 
        trc%now%H         = mv 

        trc%dep%time      = mv 
        trc%dep%H         = mv 
        trc%dep%x         = mv 
        trc%dep%y         = mv 
        trc%dep%z         = mv 

        trc%par%id_max    = 0 

        ! Initialize the time (to one older than now)
        trc%par%time_now   = time - 1000.0
        trc%par%time_dep   = time - 1000.0 
        trc%par%time_write = time - 1000.0 

        ! Initialize random number generator 
        call random_seed() 

        return 

    end subroutine tracer_init

    subroutine tracer_update(trc,time,x,y,z,z_srf,H,ux,uy,uz,dep_now,stats_now,order)

        implicit none 

        type(tracer_class), intent(INOUT) :: trc 
        real(prec), intent(IN) :: time 
        real(prec), intent(IN) :: x(:), y(:), z(:)
        real(prec), intent(IN) :: z_srf(:,:), H(:,:)
        real(prec), intent(IN) :: ux(:,:,:), uy(:,:,:), uz(:,:,:)
        logical, intent(IN) :: dep_now, stats_now  
        character(len=*), intent(IN), optional :: order 
        
        ! Local variables  
        character(len=3) :: idx_order 
        real(prec) :: zc(size(z))   ! Actual cartesian z-axis after applying sigma*H 
        integer    :: i, j, k, nx, ny, nz, ksrf, kbase  
        real(prec), allocatable :: x1(:), y1(:), z1(:)
        real(prec), allocatable :: z_srf1(:,:), H1(:,:)
        real(prec), allocatable :: ux1(:,:,:), uy1(:,:,:), uz1(:,:,:)
        logical :: z_descending 

        real(prec), allocatable :: usig1(:,:,:)

        ! Update current time 
        trc%par%time_old = trc%par%time_now 
        trc%par%time_now = time 
        trc%par%dt       = trc%par%time_now - trc%par%time_old 

        if (dep_now) trc%par%time_dep = trc%par%time_now 

        ! Determine order of indices (default ijk)
        idx_order = "ijk"
        if (present(order)) idx_order = trim(order)

        ! Also determine whether z-axis is ascending or descending 
        call tracer_reshape3D(idx_order,x,y,z,ux,uy,uz,x1,y1,z1,ux1,uy1,uz1)
        call tracer_reshape2D_field(idx_order,x1,y1,z_srf,z_srf1)
        call tracer_reshape2D_field(idx_order,x1,y1,H,H1)

        ! Note: GRISLI (nx,ny,nz): sigma goes from 1 to 0, so sigma(1)=1 [surface], sigma(nz)=0 [base]
        !       SICO (nz,ny,nx): sigma(1) = 0, sigma(nz) = 1
        ! Using tracer_reshape3D homogenizes them to ascending z-axis (nx,ny,nz)
        
        nz = size(ux1,3)
        z_descending = .FALSE. 
        if (z1(1) .gt. z1(nz)) z_descending = .TRUE. 

        ! Determine size of y-axis, if it is one, this is a 2D profile domain
        ny = size(y1,1)

        ! Get nx for completeness 
        nx = size(x1,1)

        kbase = 1
        ksrf = nz 
        if (z_descending) then 
            kbase = nz 
            ksrf  = 1 
        end if

        if (trim(trc%par%interp_method) .eq. "spline") then

            ! Allocate z-velocity field in sigma coordinates 
            if (allocated(usig1)) deallocate(usig1)
            allocate(usig1(nx,ny,nz))

            usig1 = 0.0
            do k = 1, nz 
                where (H1 .gt. 0.0) usig1(:,:,k) = uz1(:,:,k) / H1
            end do 

            call interp_bspline3D_weights(bspline3d_ux,x1,y1,z1,ux1)
            call interp_bspline3D_weights(bspline3d_uy,x1,y1,z1,uy1)
            call interp_bspline3D_weights(bspline3d_uz,x1,y1,z1,usig1)
            
        end if 


        ! Interpolate to the get the right elevation and other deposition quantities
        do i = 1, trc%par%n 

            if (trc%now%active(i) .eq. 2) then 

                ! == TO DO: We need 3D interpolation here!!!

                ! 1. Calc bilin weights at x/y locations
                ! 2. Get H and z-axis at that location
                ! 3. Calculate lin weights for z values 
                ! 4. Perform trilinear interpolation 

                ! Linear interpolation used for surface position 
                par_lin = interp_bilinear_weights(x1,y1,xout=trc%now%x(i),yout=trc%now%y(i))
                trc%now%H(i)     = interp_bilinear(par_lin,H1)
                trc%now%z_srf(i) = interp_bilinear(par_lin,z_srf1)
                trc%now%z(i)     = trc%now%z_srf(i) - trc%now%dpth(i)

                ! Calculate zc-axis for the current point
                ! (z_bedrock + ice thickness)
                zc = (trc%now%z_srf(i)-trc%now%H(i)) + z1*trc%now%H(i)

!                 ! Ensure that the tracer z-value is not higher than the surface
!                 if (trc%now%z(i) .gt. trc%now%z_srf(i)) trc%now%z(i) = trc%now%z_srf(i)

                if (trim(trc%par%interp_method) .eq. "linear") then 
                    ! Trilinear interpolation 

                    par_lin = interp_trilinear_weights(x1,y1,zc,xout=trc%now%x(i),yout=trc%now%y(i),zout=trc%now%z(i))

                    trc%now%ux(i)  = interp_trilinear(par_lin,ux1)
                    trc%now%uy(i)  = interp_trilinear(par_lin,uy1)
                    trc%now%uz(i)  = interp_trilinear(par_lin,uz1)

    !                 trc%now%ux(i)  = interp_bilinear(par_lin,ux1(:,:,nz))
    !                 trc%now%uy(i)  = interp_bilinear(par_lin,uy1(:,:,nz))
    !                 trc%now%uz(i)  = interp_bilinear(par_lin,uz1(:,:,nz))
    !                 ! Until trilinear interp is ready, maintain z-position at surface
    !                 trc%now%z(i)   = interp_bilinear(par_lin,z_srf1)

                else
                    ! Spline interpolation 
                    trc%now%ux(i) = interp_bspline3D(bspline3d_ux,trc%now%x(i),trc%now%y(i),trc%now%z(i)/trc%now%H(i))
                    trc%now%uy(i) = interp_bspline3D(bspline3d_uy,trc%now%x(i),trc%now%y(i),trc%now%z(i)/trc%now%H(i))
                    trc%now%uz(i) = interp_bspline3D(bspline3d_uz,trc%now%x(i),trc%now%y(i),trc%now%z(i)/trc%now%H(i)) *trc%now%H(i)  ! sigma => m

                end if 

                trc%now%T(i)   = 260.0 
                trc%now%thk(i) = 0.3 

!                 write(*,*) i, trc%now%z(i), trc%now%uz(i), maxval(zc), maxval(z1)

            end if 

        end do 

        ! Update the tracer thickness, then destroy points that are too thin 
        ! == TO DO == 

        ! Update the tracer positions 
        call calc_position(trc%now%x,trc%now%y,trc%now%z,trc%now%ux,trc%now%uy,trc%now%uz,trc%par%dt,trc%now%active)
!         call calc_position(trc%now%x,trc%now%y,trc%now%dpth,trc%now%ux,trc%now%uy,-trc%now%uz,trc%par%dt,trc%now%active)
        trc%now%dpth = max(trc%now%z_srf - trc%now%z, 0.0) 

        ! Destroy points that moved outside the valid region 
        call tracer_deactivate(trc%par,trc%now,x1,y1,maxval(H1))

        ! Activate new tracers if desired
        if (dep_now) call tracer_activate(trc%par,trc%now,x1,y1,H=H1,nmax=trc%par%n_max_dep)

        ! Finish activation for necessary points 
        do i = 1, trc%par%n 

            if (trc%now%active(i) .eq. 1) then 
                ! Point became active now, further initializations needed below

                ! Point is at the surface, so only bilinear interpolation is needed
                par_lin = interp_bilinear_weights(x1,y1,xout=trc%now%x(i),yout=trc%now%y(i))

                ! Apply interpolation weights to variables
                trc%now%dpth(i)  = 1.0   ! Always deposit below the surface (eg 1 m) to avoid zero z-velocity
                trc%now%z_srf(i) = interp_bilinear(par_lin,z_srf1)
                trc%now%z(i)     = trc%now%z_srf(i)-trc%now%dpth(i)
                
                trc%now%H(i)     = interp_bilinear(par_lin,H1)
                trc%now%ux(i)    = interp_bilinear(par_lin,ux1(:,:,ksrf))
                trc%now%uy(i)    = interp_bilinear(par_lin,uy1(:,:,ksrf))
                trc%now%uz(i)    = interp_bilinear(par_lin,uz1(:,:,ksrf)) 

                ! Initialize state variables
                trc%now%T(i)   = 260.0 
                trc%now%thk(i) = 0.3 

                ! Define deposition values 
                trc%dep%time(i) = trc%par%time_now 
                trc%dep%H(i)    = trc%now%H(i)
                trc%dep%x(i)    = trc%now%x(i)
                trc%dep%y(i)    = trc%now%y(i)
                trc%dep%z(i)    = trc%now%z(i) 

                trc%now%active(i) = 2 

            end if 

        end do 


        ! == TO DO == 
        ! - Attach whatever information we want to trace (age, deposition elevation and location, climate, isotopes, etc)
        ! - Potentially attach this information via a separate subroutine, using a flag to see if
        !   it was just deposited, then in main program calling eg, tracer_add_dep_variable(trc,"T",T),
        !   where the argument "T" should match a list of available variables, and T should be the variable
        !   to be stored from the main program. 

        ! Update summary statistics 
        trc%par%n_active = count(trc%now%active.gt.0)

        ! Calculate some summary information on eulerian grid if desired 
        if (stats_now) call calc_tracer_stats(trc,x,y,z,z_srf,H)

        return 

    end subroutine tracer_update

    subroutine tracer_end(trc)

        implicit none 

        type(tracer_class),   intent(OUT) :: trc 
        
        ! Allocate the state variables 
        call tracer_deallocate(trc%now,trc%dep)

        write(*,*) "tracer:: tracer object deallocated."
        
        return 

    end subroutine tracer_end

    ! ================================================
    !
    ! tracer management 
    !
    ! ================================================
    
    subroutine tracer_activate(par,now,x,y,H,nmax)
        ! Use this to activate individual or multiple tracers (not more than nmax)
        ! Only determine x/y position here, later interpolate z_srf and deposition
        ! information 

        implicit none 

        type(tracer_par_class),   intent(INOUT) :: par 
        type(tracer_state_class), intent(INOUT) :: now 
        real(prec), intent(IN) :: x(:), y(:)
        real(prec), intent(IN) :: H(:,:)
        integer, intent(IN) :: nmax  

        integer :: ntot  
        real(prec) :: p(size(H,1),size(H,2)), p_init(size(H,1),size(H,2))
        integer :: i, j, k, ij(2)
        real(prec), allocatable :: jit(:,:), dens(:,:)
        real(prec) :: xmin, ymin, xmax, ymax 

        ! How many points can be activated?
        ntot = min(nmax,count(now%active == 0))

        ! Determine initial desired distribution of points on low resolution grid
        p_init = gen_distribution(H,H_min=par%H_min_dep,alpha=par%alpha,dist=par%dist)
        p = p_init  

        ! Generate random numbers to populate points 
        allocate(jit(2,ntot))
        call random_number(jit)
        jit = (jit - 0.5)
        jit(1,:) = jit(1,:)*(x(2)-x(1)) 

        if (size(y,1) .gt. 2) then 
            jit(2,:) = jit(2,:)*(y(2)-y(1)) 
        else   ! Profile
            jit(2,:) = 0.0 
        end if 

!         write(*,*) "range jit: ", minval(jit), maxval(jit)
!         write(*,*) "npts: ", count(now%active == 0)
!         write(*,*) "ntot: ", ntot 
!         stop 
    
        ! Calculate domain boundaries to be able to apply limits 
        xmin = minval(x) 
        xmax = maxval(x) 
        ymin = minval(y) 
        ymax = maxval(y) 

        if (maxval(p_init) .gt. 0.0) then 
            ! Activate points in locations with non-zero probability
            ! This if-statement ensures some valid points currently exist in the domain
            
            k = 0 

            do j = 1, par%n 

                if (now%active(j)==0) then 

                    now%active(j) = 1
                    k = k + 1
                    par%id_max = par%id_max+1 
                    now%id(j)  = par%id_max 

                    ij = maxloc(p,mask=p.gt.0.0)
                    now%x(j) = x(ij(1)) + jit(1,k)
                    now%y(j) = y(ij(2)) + jit(2,k)
                    
                    if (now%x(j) .lt. xmin) now%x(j) = xmin 
                    if (now%x(j) .gt. xmax) now%x(j) = xmax 
                    if (now%y(j) .lt. ymin) now%y(j) = ymin 
                    if (now%y(j) .gt. ymax) now%y(j) = ymax 
                    
                    p(ij(1),ij(2)) = 0.0 
                     
                end if 

                ! Stop when all points have been allocated
                if (k .ge. ntot) exit 

                ! If there are no more points with non-zero probability, reset probability
                if (maxval(p) .eq. 0.0) p = p_init 

            end do 
          
        end if

        ! Summary 
        write(*,*) "tracer_activate:: ", count(now%active == 0), count(now%active .eq. 1), count(now%active .eq. 2)

        return 

    end subroutine tracer_activate 

    subroutine tracer_deactivate(par,now,x,y,Hmax)
        ! Use this to deactivate individual or multiple tracers
        implicit none 

        type(tracer_par_class),   intent(INOUT) :: par 
        type(tracer_state_class), intent(INOUT) :: now 
        real(prec), intent(IN) :: x(:), y(:) 
        real(prec), intent(IN) :: Hmax 

        ! Deactivate points where:
        !  - Thickness of ice sheet at point's location is below threshold
        !  - Point is above maximum ice thickness Hmax (interp error)
        !  - Point is past maximum depth into the ice sheet 
        !  - Velocity of point is higher than maximum threshold 
        !  - x/y position is out of boundaries of the domain 
        where (now%active .gt. 0 .and. &
              ( now%H .lt. par%H_min                           .or. &
                now%H .gt. Hmax                                .or. &
                now%dpth/now%H .ge. par%depth_max              .or. &
                sqrt(now%ux**2 + now%uy**2) .gt. par%U_max     .or. &
                now%x .lt. minval(x) .or. now%x .gt. maxval(x) .or. &
                now%y .lt. minval(y) .or. now%y .gt. maxval(y) ) ) 

            now%active    = 0 

            now%id        = mv 
            now%x         = mv 
            now%y         = mv 
            now%z         = mv 
            now%sigma     = mv 
            now%z_srf     = mv 
            now%dpth      = mv 
            now%ux        = mv 
            now%uy        = mv 
            now%uz        = mv 
            now%thk       = mv 
            now%T         = mv 
            now%H         = mv 

        end where 

        return 

    end subroutine tracer_deactivate 

    ! ================================================
    !
    ! tracer physics / stats
    !
    ! ================================================
    
    elemental subroutine calc_position(x,y,z,ux,uy,uz,dt,active)

        implicit none 

        real(prec), intent(INOUT) :: x, y, z 
        real(prec), intent(IN)    :: ux, uy, uz 
        real(prec), intent(IN)    :: dt 
        integer,    intent(IN)    :: active 

        if (active .gt. 0) then 
            x = x + ux*dt 
            y = y + uy*dt 
            z = z + uz*dt 
        end if 

        return 

    end subroutine calc_position

    function gen_distribution(H,H_min,alpha,dist) result(p)

        implicit none 

        real(prec), intent(IN) :: H(:,:)
        real(prec), intent(IN) :: H_min, alpha 
        character(len=*), intent(IN) :: dist 
        real(prec) :: p(size(H,1),size(H,2))

        ! Local variables
        integer    :: k, ij(2)
        real(prec) :: p_sum 

        select case(trim(dist)) 

            case("linear")

                p = (alpha * max(H-H_min,0.0) / (maxval(H)-H_min))

            case("quadratic")

                p = (alpha * max(H-H_min,0.0) / (maxval(H)-H_min))**2

            case DEFAULT

                ! Even distribution (all points equally likely)
                p = 1.0
                where (H .lt. H_min) p = 0.0 


        end select 

        ! Normalize probability sum to one 
        p_sum = sum(p)
        if (p_sum .gt. 0.0) p = p / p_sum

        return 

    end function gen_distribution

    subroutine calc_tracer_stats(trc,x,y,z,z_srf,H)
        ! Convert tracer information to isochrone format matching
        ! Macgregor et al. (2015)

        implicit none
        
        type(tracer_class), intent(INOUT) :: trc
        real(prec), intent(IN) :: x(:), y(:), z(:), z_srf(:,:), H(:,:)

        ! Local variables 
        integer :: i, j, k, q
        integer :: nx, ny, nz, nq
        real(prec), allocatable :: dx(:), dy(:) 
        real(prec) :: dt, dz, dz_now  
        real(prec) :: zc(size(z))
        integer       :: id(trc%par%n)
        real(prec)    :: dist(trc%par%n)
        integer, allocatable :: inds(:)
        integer :: n_ind 

        nx = size(x)
        ny = size(y)
        
        allocate(dx(nx+1),dy(ny+1))
        dx(2:nx) = (x(2:nx)-x(1:nx-1))/2.0
        dx(1)    = dx(2)
        dx(nx+1) = dx(nx)
        dy(2:ny) = (y(2:ny)-y(1:ny-1))/2.0
        dy(1)    = dy(2)
        dy(ny+1) = dy(ny)
        
        dt = 1.0 ! Isochrone uncertainty of 1 ka  
        dz = (trc%stats%depth_norm(2) - trc%stats%depth_norm(1))/2.0   ! depth_norm is equally spaced
        
        ! Loop over grid and fill in information
        do j = 1, ny 
        do i = 1, nx 

            ! Calculate the isochrones
            nq = size(trc%stats%age_iso)
            do q = 1, nq 

                ! Filter for active particles within the grid box and age of interest
                call which (trc%now%active == 2 .and. &
                            trc%now%x .gt. x(i)-dx(i) .and. trc%now%x .le. x(i)+dx(i+1) .and. &
                            trc%now%y .gt. y(j)-dy(j) .and. trc%now%y .le. y(j)+dy(j+1) .and. &
                            (0.0 - trc%dep%time)*1e-3 .ge. trc%stats%age_iso(q)-dt .and. &
                            (0.0 - trc%dep%time)*1e-3 .le. trc%stats%age_iso(q)+dt, inds, n_ind) 

                ! Calculate range mean/sd depth for given age range
                if (n_ind .gt. 0) then
                    write(*,*) "isochrones: ", i, j, q, n_ind 
 
                    trc%stats%depth_iso(i,j,q)     = calc_mean(trc%now%dpth(inds))
                    trc%stats%depth_iso_err(i,j,q) = calc_sd(trc%now%dpth(inds),trc%stats%depth_iso(i,j,q))
                    trc%stats%density_iso(i,j,q)   = n_ind 
                else 
                    trc%stats%depth_iso(i,j,q)     = MV 
                    trc%stats%depth_iso_err(i,j,q) = MV
                    trc%stats%density_iso(i,j,q)   = MV
 
                end if 

            end do 
            
            ! Calculate the ages of each depth layer 
            nq = size(trc%stats%depth_norm)
            do q = 1, nq 

                ! Use dz_now to ensure that the first depth (0.04) includes all depths to the surface
                dz_now = dz 
                if (q .eq. 1) dz_now = dz*5.0 

                ! Filter for active particles within the grid box and age of interest
                call which (trc%now%active == 2 .and. &
                            trc%now%x .gt. x(i)-dx(i) .and. trc%now%x .le. x(i)+dx(i+1) .and. &
                            trc%now%y .gt. y(j)-dy(j) .and. trc%now%y .le. y(j)+dy(j+1) .and. &
                            trc%now%dpth/trc%now%H .gt. trc%stats%depth_norm(q)-dz_now  .and. &
                            trc%now%dpth/trc%now%H .le. trc%stats%depth_norm(q)+dz, inds, n_ind) 

                ! Calculate range mean/sd age for given depth range
                if (n_ind .gt. 0) then
                    write(*,*) "ice_ages: ", i, j, q, n_ind 
 
                    trc%stats%ice_age(i,j,q)     = calc_mean(trc%dep%time(inds))*1e-3
                    trc%stats%ice_age_err(i,j,q) = calc_sd(trc%dep%time(inds),trc%stats%ice_age(i,j,q))*1e-3
                    trc%stats%density(i,j,q)     = n_ind 
                else 
                    trc%stats%ice_age(i,j,q)     = MV 
                    trc%stats%ice_age_err(i,j,q) = MV 
                    trc%stats%density(i,j,q)     = MV 
                end if  

            end do 

        end do 
        end do  
        
        return

    end subroutine calc_tracer_stats

    function calc_mean(x) result(mean)

        implicit none 

        real(prec), intent(IN) :: x(:) 
        real(prec) :: mean 
        integer :: n 

        n = count(x.ne.MV)

        if (n .gt. 0) then 
            mean = sum(x,mask=x.ne.MV) / real(n)
        else 
            mean = MV 
        end if 
        
        return 

    end function calc_mean 

    function calc_sd(x,mean) result(stdev)

        implicit none 

        real(prec), intent(IN) :: x(:) 
        real(prec) :: mean 
        real(prec) :: stdev 
        integer :: n 

        n = count(x.ne.MV)

        if (n .gt. 0) then 
            stdev = sqrt( sum((x - mean)**2) / real(n) )
        else 
            stdev = MV 
        end if 

        return 

    end function calc_sd 

    ! ================================================
    !
    ! Initialization routines 
    !
    ! ================================================

    subroutine tracer_par_load(par,filename,is_sigma)

        implicit none 

        type(tracer_par_class), intent(OUT) :: par 
        character(len=*),       intent(IN)  :: filename 
        logical, intent(IN) :: is_sigma 

!         par%n         = 5000
!         par%n_max_dep = 100
        
!         par%thk_min   = 1e-2   ! m (minimum thickness of tracer 'layer')
!         par%H_min     = 1500.0 ! m 
!         par%depth_max = 0.99   ! fraction of thickness
!         par%U_max     = 200.0  ! m/a 

!         par%H_min_dep = 1000.0 ! m 
!         par%alpha     = 1.0 
!         par%dist      = "linear"
        
!         par%dens_z_lim = 50.0 ! m
!         par%dens_max   = 10   ! Number of points
        
        call nml_read(filename,"tracer_par","n",            par%n)
        call nml_read(filename,"tracer_par","n_max_dep",    par%n_max_dep)
        call nml_read(filename,"tracer_par","thk_min",      par%thk_min)
        call nml_read(filename,"tracer_par","H_min",        par%H_min)
        call nml_read(filename,"tracer_par","depth_max",    par%depth_max)
        call nml_read(filename,"tracer_par","U_max",        par%U_max)
        call nml_read(filename,"tracer_par","H_min_dep",    par%H_min_dep)
        call nml_read(filename,"tracer_par","alpha",        par%alpha)
        call nml_read(filename,"tracer_par","dist",         par%dist)
        call nml_read(filename,"tracer_par","dens_z_lim",   par%dens_z_lim)
        call nml_read(filename,"tracer_par","dens_max",     par%dens_max)
        call nml_read(filename,"tracer_par","interp_method",par%interp_method)
        
        ! Define additional parameter values
        par%is_sigma  = is_sigma 
        par%n_active  = 0 
        par%time_now  = 0.0             ! year
        par%time_old  = 0.0             ! year
        par%dt        = 0.0             ! year

        ! Consistency checks 
        if (trim(par%interp_method) .ne. "linear" .and. &
            trim(par%interp_method) .ne. "spline" ) then 
            write(0,*) "tracer_init:: error: interp_method must be 'linear' &
            &or 'spline': "//trim(par%interp_method)
            stop 
        end if 

        return 

    end subroutine tracer_par_load
    

    subroutine tracer_allocate(now,dep,n)

        implicit none 

        type(tracer_state_class), intent(INOUT) :: now 
        type(tracer_dep_class),   intent(INOUT) :: dep
        integer, intent(IN) :: n

        ! Make object is deallocated
        call tracer_deallocate(now,dep)

        ! Allocate tracer 
        allocate(now%active(n))
        allocate(now%id(n))
        allocate(now%x(n),now%y(n),now%z(n),now%sigma(n))
        allocate(now%z_srf(n),now%dpth(n))
        allocate(now%ux(n),now%uy(n),now%uz(n))
        allocate(now%thk(n))
        allocate(now%T(n))
        allocate(now%H(n))

        ! Allocate deposition properties 
        
        allocate(dep%time(n), dep%H(n))
        allocate(dep%x(n), dep%y(n), dep%z(n), dep%lon(n), dep%lat(n))
        allocate(dep%t2m(4,n), dep%pr(4,n), dep%t2m_prann(n))
        
        return

    end subroutine tracer_allocate

    subroutine tracer_deallocate(now,dep)

        implicit none 

        type(tracer_state_class), intent(INOUT) :: now 
        type(tracer_dep_class),   intent(INOUT) :: dep
        
        ! Deallocate state objects
        if (allocated(now%active))    deallocate(now%active)
        if (allocated(now%x))         deallocate(now%x)
        if (allocated(now%y))         deallocate(now%y)
        if (allocated(now%z))         deallocate(now%z)
        if (allocated(now%sigma))     deallocate(now%sigma)
        if (allocated(now%z_srf))     deallocate(now%z_srf)
        if (allocated(now%dpth))      deallocate(now%dpth)
        if (allocated(now%ux))        deallocate(now%ux)
        if (allocated(now%uy))        deallocate(now%uy)
        if (allocated(now%uz))        deallocate(now%uz)
        if (allocated(now%thk))       deallocate(now%thk)
        if (allocated(now%T))         deallocate(now%T)
        if (allocated(now%H))         deallocate(now%H)

        ! Deallocate deposition objects
        if (allocated(dep%time))      deallocate(dep%time)
        if (allocated(dep%z))         deallocate(dep%z)
        if (allocated(dep%H))         deallocate(dep%H)
        if (allocated(dep%x))         deallocate(dep%x)
        if (allocated(dep%y))         deallocate(dep%y)
        if (allocated(dep%lon))       deallocate(dep%lon)
        if (allocated(dep%lat))       deallocate(dep%lat)
        if (allocated(dep%t2m))       deallocate(dep%t2m)
        if (allocated(dep%pr))        deallocate(dep%pr)
        if (allocated(dep%t2m_prann)) deallocate(dep%t2m_prann)
        
        return

    end subroutine tracer_deallocate

    subroutine tracer_allocate_stats(stats,x,y)

        implicit none 

        type(tracer_stats_class), intent(INOUT) :: stats 
        real(prec), intent(IN) :: x(:), y(:)
        
        ! Make surce object is deallocated
        call tracer_deallocate_stats(stats)

        ! Allocate tracer stats axes
        allocate(stats%x(size(x)))
        allocate(stats%y(size(y)))

        ! Allocate tracer stats objects
        allocate(stats%depth_norm(25))  ! To match Macgregor et al. (2015)
        allocate(stats%age_iso(5))      ! To match Macgregor et al. (2015)
        allocate(stats%depth_iso(size(x),size(y),size(stats%age_iso)))
        allocate(stats%depth_iso_err(size(x),size(y),size(stats%age_iso)))
        allocate(stats%ice_age(size(x),size(y),size(stats%depth_norm)))
        allocate(stats%ice_age_err(size(x),size(y),size(stats%depth_norm)))
        allocate(stats%density(size(x),size(y),size(stats%depth_norm)))
        allocate(stats%density_iso(size(x),size(y),size(stats%age_iso)))

        ! Also store axis information directly
        stats%x = x 
        stats%y = y 

        ! Initialize arrays to zeros 
        stats%depth_iso     = 0.0 
        stats%depth_iso_err = 0.0 
        stats%ice_age       = 0.0 
        stats%ice_age_err   = 0.0 
        stats%density       = MV 
        stats%density_iso   = MV 

        return

    end subroutine tracer_allocate_stats

    subroutine tracer_deallocate_stats(stats)

        implicit none 

        type(tracer_stats_class), intent(INOUT) :: stats 

        ! Deallocate stats objects
        if (allocated(stats%x))             deallocate(stats%x)
        if (allocated(stats%y))             deallocate(stats%y)
        if (allocated(stats%depth_norm))    deallocate(stats%depth_norm)
        if (allocated(stats%age_iso))       deallocate(stats%age_iso)
        if (allocated(stats%depth_iso))     deallocate(stats%depth_iso)
        if (allocated(stats%depth_iso_err)) deallocate(stats%depth_iso_err)
        if (allocated(stats%ice_age))       deallocate(stats%ice_age)
        if (allocated(stats%ice_age_err))   deallocate(stats%ice_age_err)
        if (allocated(stats%density))       deallocate(stats%density)
        if (allocated(stats%density_iso))   deallocate(stats%density_iso)

        return

    end subroutine tracer_deallocate_stats

    subroutine tracer_reshape3D(idx_order,x,y,z,ux,uy,uz,x1,y1,z1,ux1,uy1,uz1)

        implicit none 

        character(len=3), intent(IN) :: idx_order 
        real(prec), intent(IN) :: x(:), y(:), z(:)
        real(prec), intent(IN) :: ux(:,:,:), uy(:,:,:), uz(:,:,:)

        real(prec), intent(INOUT), allocatable :: x1(:), y1(:), z1(:)
        real(prec), intent(INOUT), allocatable :: ux1(:,:,:), uy1(:,:,:), uz1(:,:,:)
        integer :: i, j, k
        integer :: nx, ny, nz 

        nx = size(x)
        ny = size(y)
        nz = size(z) 

        if (allocated(x1))  deallocate(x1)
        if (allocated(y1))  deallocate(y1)
        if (allocated(z1))  deallocate(z1)
        if (allocated(ux1)) deallocate(ux1)
        if (allocated(uy1)) deallocate(uy1)
        if (allocated(uz1)) deallocate(uz1)

        allocate(x1(nx))
        allocate(y1(ny))
        allocate(z1(nz))
        allocate(ux1(nx,ny,nz))
        allocate(uy1(nx,ny,nz))
        allocate(uz1(nx,ny,nz))
        
        x1 = x 
        y1 = y 

        select case(trim(idx_order))

            case("ijk")
                ! x, y, z array order 

!                 if (z(1) .lt. z(nz)) then 
!                     ! Already ascending z-axis

                    z1  = z  
                    ux1 = ux 
                    uy1 = uy 
                    uz1 = uz 

!                 else   
!                     ! Reversed z-axis 
!                     do k = 1, nz 
!                         z1(k)      = z(nz-k+1)
!                         ux1(:,:,k) = ux(:,:,nz-k+1)
!                         uy1(:,:,k) = uy(:,:,nz-k+1)
!                         uz1(:,:,k) = uz(:,:,nz-k+1)
!                     end do 
!                 end if 

            case("kji")
                ! z, y, x array order 

!                 if (z(1) .lt. z(nz)) then 
!                     ! Already ascending z-axis

                    z1  = z  
                    do i = 1, nx 
                    do j = 1, ny 
                        ux1(i,j,:) = ux(:,j,i)
                        uy1(i,j,:) = uy(:,j,i)
                        uz1(i,j,:) = uz(:,j,i)
                    end do 
                    end do 

!                 else   
!                     ! Reversed z-axis 
!                     z1  = z(nz:1)
!                     do i = 1, nx 
!                     do j = 1, ny
!                         do k = 1, nz 
!                             ux1(i,j,k) = ux(nz-k+1,j,i)
!                             uy1(i,j,k) = uy(nz-k+1,j,i)
!                             uz1(i,j,k) = uz(nz-k+1,j,i)
!                         end do 
!                     end do 
!                     end do 

!                 end if 

            case DEFAULT 

                write(0,*) "tracer_reshape3D:: error: unrecognized array order: ",trim(idx_order)
                write(0,*) "    Possible choices are: ijk, kji"
                stop  

        end select 

        return 

    end subroutine tracer_reshape3D

    subroutine tracer_reshape2D_field(idx_order,x1,y1,var,var1)

        implicit none 

        character(len=3), intent(IN) :: idx_order 
        real(prec), intent(IN) :: var(:,:)
        real(prec), intent(IN) :: x1(:), y1(:)
        real(prec), intent(INOUT), allocatable :: var1(:,:)
        integer :: i, j
        integer :: nx, ny

        nx = size(x1)
        ny = size(y1)

        if (allocated(var1)) deallocate(var1)
        allocate(var1(nx,ny))

        select case(trim(idx_order))

            case("ijk")
                ! x, y, z array order 

                var1 = var 

            case("kji")
                ! z, y, x array order 

                do i = 1, nx 
                do j = 1, ny 
                    var1(i,j)  = var(j,i)
                end do 
                end do 

            case DEFAULT 

                write(0,*) "tracer_reshape2D_field:: error: unrecognized array order: ",trim(idx_order)
                write(0,*) "    Possible choices are: ijk, kji"
                stop  

        end select 

        return 

    end subroutine tracer_reshape2D_field

    ! ================================================
    !
    ! I/O routines 
    !
    ! ================================================

    subroutine tracer_write_init(trc,fldr,filename)

        implicit none 

        type(tracer_class), intent(IN) :: trc 
        character(len=*), intent(IN)   :: fldr, filename 

        ! Local variables 
        integer :: nt 
        character(len=512) :: path_out 

        path_out = trim(fldr)//"/"//trim(filename)

        ! Create output file 
        call nc_create(path_out)
        call nc_write_dim(path_out,"pt",x=1,dx=1,nx=trc%par%n)
        call nc_write_dim(path_out,"time",x=mv,unlimited=.TRUE.)

        return 

    end subroutine tracer_write_init 

    subroutine tracer_write(trc,time,fldr,filename)

        implicit none 

        type(tracer_class), intent(INOUT) :: trc 
        real(prec) :: time 
        character(len=*), intent(IN)   :: fldr, filename 

        ! Local variables 
        integer :: nt
        integer, allocatable :: dims(:)
        real(prec) :: time_in  
        character(len=512) :: path_out 

        real(prec) :: tmp(size(trc%now%x))

        trc%par%time_write = time 

        path_out = trim(fldr)//"/"//trim(filename)

        ! Determine which timestep this is
        call nc_dims(path_out,"time",dims=dims)
        nt = dims(1)
        call nc_read(path_out,"time",time_in,start=[nt],count=[1])
        if (time_in .ne. MV .and. abs(time-time_in).gt.1e-2) nt = nt+1 

        call nc_write(path_out,"time",time,dim1="time",start=[nt],count=[1],missing_value=MV)
        
        call nc_write(path_out,"n_active",trc%par%n_active,dim1="time",start=[nt],count=[1],missing_value=int(MV))
        
        tmp = trc%now%x
        where(trc%now%x .ne. MV) tmp = trc%now%x*1e-3
        call nc_write(path_out,"x",tmp,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        tmp = trc%now%y
        where(trc%now%y .ne. MV) tmp = trc%now%y*1e-3
        call nc_write(path_out,"y",tmp,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"z",trc%now%z,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"dpth",trc%now%dpth,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"z_srf",trc%now%z_srf,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"ux",trc%now%ux,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"uy",trc%now%uy,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"uz",trc%now%uz,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"thk",trc%now%thk,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"T",trc%now%T,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"H",trc%now%H,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])

        call nc_write(path_out,"id",trc%now%id,dim1="pt",dim2="time", missing_value=int(MV), &
                        start=[1,nt],count=[trc%par%n ,1])

        ! Write deposition information
        call nc_write(path_out,"dep_time",trc%dep%time,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"dep_H",trc%dep%H,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        tmp = trc%dep%x
        where(trc%dep%x .ne. MV) tmp = trc%dep%x*1e-3
        call nc_write(path_out,"dep_x",tmp,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        tmp = trc%dep%y
        where(trc%dep%y .ne. MV) tmp = trc%dep%y*1e-3
        call nc_write(path_out,"dep_y",tmp,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])
        call nc_write(path_out,"dep_z",trc%dep%z,dim1="pt",dim2="time", missing_value=MV, &
                        start=[1,nt],count=[trc%par%n ,1])

        return 

    end subroutine tracer_write 

    subroutine tracer_write_stats(trc,time,fldr,filename) !,z_srf,H)
        ! Write various meta-tracer information (ie, lagrangian => eulerian)
        ! This output belongs to a specific time slice, usually at time = 0 ka BP. 

        implicit none 

        type(tracer_class), intent(IN) :: trc 
        real(prec) :: time
        character(len=*),   intent(IN) :: fldr, filename 
!         real(prec),         intent(IN) :: z_srf(:,:), H(:,:) 

        ! Local variables 
        character(len=512) :: path_out 

        path_out = trim(fldr)//"/"//trim(filename)

        ! Create output file 
        call nc_create(path_out)
        call nc_write_dim(path_out,"xc",        x=trc%stats%x*1e-3,     units="km")
        call nc_write_dim(path_out,"yc",        x=trc%stats%y*1e-3,     units="km")
        call nc_write_dim(path_out,"depth_norm",x=trc%stats%depth_norm, units="1")
        call nc_write_dim(path_out,"age_iso",   x=trc%stats%age_iso,    units="ka")
        call nc_write_dim(path_out,"time",      x=time,unlimited=.TRUE.,units="ka")
        
!         call nc_write(path_out,"z_srf",z_srf,dim1="xc",dim2="yc",missing_value=MV, &
!                       units="m",long_name="Surface elevation")
!         call nc_write(path_out,"H",H,dim1="xc",dim2="yc",missing_value=MV, &
!                       units="m",long_name="Ice thickness")

        call nc_write(path_out,"ice_age",trc%stats%ice_age,dim1="xc",dim2="yc",dim3="depth_norm",missing_value=MV, &
                      units="ka",long_name="Layer age")
        call nc_write(path_out,"ice_age_err",trc%stats%ice_age_err,dim1="xc",dim2="yc",dim3="depth_norm",missing_value=MV, &
                      units="ka",long_name="Layer age - error")
        call nc_write(path_out,"density",trc%stats%density,dim1="xc",dim2="yc",dim3="depth_norm",missing_value=int(MV), &
                      units="1",long_name="Tracer density")

        call nc_write(path_out,"depth_iso",trc%stats%depth_iso,dim1="xc",dim2="yc",dim3="age_iso",missing_value=MV, &
                      units="ka",long_name="Isochrone depth")
        call nc_write(path_out,"depth_iso_err",trc%stats%depth_iso_err,dim1="xc",dim2="yc",dim3="age_iso",missing_value=MV, &
                      units="ka",long_name="Isochrone depth - error")
        call nc_write(path_out,"density_iso",trc%stats%density_iso,dim1="xc",dim2="yc",dim3="age_iso",missing_value=int(MV), &
                      units="1",long_name="Tracer density (for isochrones)")

        
        return 

    end subroutine tracer_write_stats

    subroutine tracer_read()

        implicit none 



        return 

    end subroutine tracer_read

    subroutine which(x,ind,stat)
        ! Analagous to R::which function
        ! Returns indices that match condition x==.TRUE.

        implicit none 

        logical :: x(:)
        integer, allocatable :: tmp(:), ind(:)
        integer, optional :: stat  
        integer :: n, i  

        n = count(x)
        allocate(tmp(n))
        tmp = 0 

        n = 0
        do i = 1, size(x) 
            if (x(i)) then 
                n = n+1
                tmp(n) = i 
            end if
        end do 

        if (present(stat)) stat = n 

        if (allocated(ind)) deallocate(ind)

        if (n .eq. 0) then 
            allocate(ind(1))
            ind = -1 
        else
            allocate(ind(n))
            ind = tmp(1:n)
        end if 
        
        return 

    end subroutine which

end module tracer 


