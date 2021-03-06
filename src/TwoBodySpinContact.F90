module TwoBodySpinContact
  use OneBodyTerms
  use TwoBodyTerms
  use ElectronTwoBodySpace
  implicit none

  private :: set_ee_spin_contact_term
  private :: ee_spin_contact_interaction
  private :: spin_sph
  private :: finalize_fnl
  private :: initialize_fnl_laguerre
  private :: get_fnl

  type, private :: FL
    real(8) :: F
  end type FL

  type, private :: Fnl
    type(FL), allocatable :: bk(:,:)
    integer, allocatable :: idx(:,:,:,:)
    integer, allocatable :: n1(:)
    integer, allocatable :: n2(:)
    integer, allocatable :: l1(:)
    integer, allocatable :: l2(:)
    integer :: nidx
  contains
    procedure :: initialize_fnl_laguerre
    procedure :: finalize_fnl
    procedure :: get_fnl
  end type Fnl
  type(Fnl), private :: Fintegral
  real(8), private, allocatable :: rmesh(:), rwmesh(:)
  real(8), private, allocatable :: rnl(:,:,:)
contains

  subroutine set_ee_spin_contact_laguerre( this, ms, NMesh, rmax )
    use AtLibrary, only: gauss_legendre, laguerre_radial_wf_norm, &
        & fixed_point_quadrature, ln_gamma, laguerre
    type(TwoBodyOperator), intent(inout) :: this
    type(EleTwoBodySpace), intent(in) :: ms
    integer, intent(in) :: NMesh
    integer :: n, l, i
    real(8) :: rmax, time
    write(*,*)
    write(*,"(a)") " Electron-electron spin-spin contact: "
#ifdef gauss_laguerre
    write(*,"(a)") "Using Gauss-Laguerre quadrature"
    call fixed_point_quadrature("laguerre", NMesh, rmesh, rwmesh, weight_renorm=.false., &
        & a_in=0.d0, b_in=2.d0, alpha_in=0.d0)
#else
    write(*,"(a)") "Using Gauss-Legendre quadrature"
    call gauss_legendre(0.d0, rmax, rmesh, rwmesh, NMesh)
#endif /* gauss_laguerre */
    allocate(rnl(NMesh, 0:ms%sps%emax, 0:ms%sps%lmax))
    rnl(:,:,:) = 0.d0
    do n = 0, ms%sps%emax
      do l = 0, ms%sps%lmax
        do i = 1, NMesh
#ifdef gauss_laguerre
          rnl(i,n,l) = laguerre_radial_wf_norm_glmesh(n, dble(l), 1.d0, rmesh(i))
#else
          rnl(i,n,l) = laguerre_radial_wf_norm(n, dble(l), 1.d0, rmesh(i))
#endif
        end do
      end do
    end do
    call norm_check(rnl, rwmesh, "lo")
    time = omp_get_wtime()
    call Fintegral%initialize_fnl_laguerre( ms )
    write(*,"(a,f12.6,a)") " Stored radial integral: ", omp_get_wtime() - time, " sec"
    time = omp_get_wtime()
    call set_ee_spin_contact_term( this, ms )
    write(*,"(a,f12.6,a)") " Calculated ee spin-spin contact: ", omp_get_wtime() - time, " sec"
    call Fintegral%finalize_fnl()
  end subroutine set_ee_spin_contact_laguerre

  subroutine set_ee_spin_contact_term( this, ms )
    type(TwoBodyOperator), intent(inout) :: this
    type(EleTwoBodySpace), intent(in), target :: ms
    type(EleOrbits), pointer :: sps
    type(EleSingleParticleOrbit), pointer :: oa, ob, oc, od
    integer :: bra, ket, a, b, c, d, J
    integer :: ch
    real(8) :: rabcd, rbacd, rabdc, rbadc, norm
    sps => ms%sps
    do ch = 1, ms%NChan
      J = ms%jp(ch)%j
      !$omp parallel
      !$omp do private(bra, a, b, oa, ob, ket, c, d, oc, od, norm, &
      !$omp &          rabcd, rbacd, rabdc, rbadc)
      do bra = 1, ms%jp(ch)%n_state
        a = ms%jp(ch)%n2label1(bra)
        b = ms%jp(ch)%n2label2(bra)
        oa => sps%orb(a)
        ob => sps%orb(b)
        do ket = 1, bra
          c = ms%jp(ch)%n2label1(ket)
          d = ms%jp(ch)%n2label2(ket)
          oc => sps%orb(c)
          od => sps%orb(d)

          norm = 1.d0
          if(a == b) norm = norm * dsqrt(0.5d0)
          if(c == d) norm = norm * dsqrt(0.5d0)
          rabcd = ee_spin_contact_interaction(oa, ob, oc, od, J)
          rbacd = ee_spin_contact_interaction(ob, oa, oc, od, J) * (-1.d0)**((oa%j+ob%j)/2-J-1)
          rabdc = ee_spin_contact_interaction(oa, ob, od, oc, J) * (-1.d0)**((oc%j+od%j)/2-J-1)
          rbadc = ee_spin_contact_interaction(ob, oa, od, oc, J) * (-1.d0)**((oa%j+ob%j+oc%j+od%j)/2)
          this%MatCh(ch,ch)%m(bra,ket) = 0.5d0 * norm * (rabcd + rbacd + rabdc + rbadc)
          this%MatCh(ch,ch)%m(ket,bra) = 0.5d0 * norm * (rabcd + rbacd + rabdc + rbadc)
        end do
      end do
      !$omp end do
      !$omp end parallel
    end do
  end subroutine set_ee_spin_contact_term

  function ee_spin_contact_interaction(oa, ob, oc, od, J) result(r)
    use AtLibrary, only: tjs, sjs, alpha
    type(EleSingleParticleOrbit), intent(in) :: oa, ob, oc, od
    integer, intent(in) :: J
    real(8) :: r, fk
    integer :: Lmin, Lmax, L, Kmin, Kmax, K
    real(8) :: integral

    Lmin = max(abs(oa%l-oc%l), abs(ob%l-od%l))
    Lmax = min(   (oa%l+oc%l),    (ob%l+od%l))
    integral = Fintegral%get_fnl(oa%n,oa%l,ob%n,ob%l,oc%n,oc%l,od%n,od%l)
    r = 0.d0
    do L = Lmin, Lmax
      if(mod(oa%l + oc%l + L, 2) == 1) cycle
      if(mod(ob%l + od%l + L, 2) == 1) cycle

      Kmin = max( abs(oa%j-oc%j)/2, abs(ob%j-od%j)/2, abs(L-1) )
      Kmax = max(    (oa%j+oc%j)/2,    (ob%j+od%j)/2,    (L+1) )
      fk = 0.d0
      do k = abs(L-1), L+1
        fk = fk + sqrt(dble(2*K+1)) * (-1.d0)**K * sjs(oa%j, ob%j, 2*J, od%j, oc%j, 2*K) * &
            & spin_sph( L, K, oa%l, oa%j, oc%l, oc%j ) * spin_sph( L, K, ob%l, ob%j, od%l, od%j )
      end do
      r = r + (-1.d0)**L * fk
    end do
    r = r * integral * (-1.d0)**((ob%j + oc%j) /2 + J) / alpha**2
  end function ee_spin_contact_interaction

  function spin_sph( L, K, la, ja, lc, jc ) result(r)
    use AtLibrary, only: tjs, snj
    integer, intent(in) :: L, K, la, ja, lc, jc
    real(8) :: r
    r = sqrt( dble( (ja+1) * (2*K+1) * (jc+1) * (2*la+1) * (2*L+1) * (2*lc+1) ) ) * &
        & snj(2*la, 2*lc, 2*L, 1, 1, 2, ja, jc, 2*K) * tjs( 2*la, 2*L, 2*lc, 0, 0, 0)
    !r = sqrt( dble( (ja+1) * (jc+1) * (2*la+1) * (2*lc+1) ) ) * &
    !    & snj(2*la, 2*lc, 2*L, 1, 1, 2, ja, jc, 2*K) * tjs( 2*la, 2*L, 2*lc, 0, 0, 0)
  end function spin_sph

  subroutine finalize_fnl(this)
    class(Fnl), intent(inout) :: this
    deallocate(this%bk)
    deallocate(this%idx)
    deallocate(this%n1)
    deallocate(this%n2)
    deallocate(this%l1)
    deallocate(this%l2)
  end subroutine finalize_fnl

  subroutine initialize_fnl_laguerre(this, ms)
    use AtLibrary, only: gauss_legendre, laguerre_radial_wf_norm
    class(Fnl), intent(inout) :: this
    type(EleTwoBodySpace), intent(in) :: ms
    type(EleOrbits), pointer :: sps
    type(EleSingleParticleOrbit), pointer :: oa
    integer :: nmin, nmax, lmin, lmax
    integer :: l1max, l2max
    integer :: a
    integer :: n1, l1, n2, l2
    integer :: n3, l3, n4, l4
    integer :: bra, ket
    integer :: cnt, i1
    real(8) :: integral, zeta
    integer :: NMesh

    sps => ms%sps
    nmax = -1
    lmax = -1
    nmin = 1000
    lmin = 1000
    zeta = ms%zeta
    do a = 1, sps%norbs
      oa => sps%orb(a)
      nmin = min(nmin, oa%n)
      lmin = min(lmin, oa%l)
      nmax = max(nmax, oa%n)
      lmax = max(lmax, oa%l)
    end do

    allocate(this%idx(nmin:nmax,lmin:lmax,nmin:nmax,lmin:lmax))
    this%idx(:,:,:,:) = 0

    cnt = 0
    do n1 = nmin, nmax
      do n2 = nmin, nmax
        l1max = lmax
        l2max = lmax
        do l1 = lmin, l1max
          do l2 = lmin, l2max
            cnt = cnt + 1
          end do
        end do
      end do
    end do
    this%nidx = cnt
    allocate(this%bk(this%nidx, this%nidx))
    allocate(this%n1(this%nidx))
    allocate(this%l1(this%nidx))
    allocate(this%n2(this%nidx))
    allocate(this%l2(this%nidx))
    cnt = 0
    do n1 = nmin, nmax
      do n2 = nmin, nmax
        l1max = lmax
        l2max = lmax
        do l1 = lmin, l1max
          do l2 = lmin, l2max
            cnt = cnt + 1
            this%idx(n1,l1,n2,l2) = cnt
            this%n1(cnt) = n1
            this%l1(cnt) = l1
            this%n2(cnt) = n2
            this%l2(cnt) = l2
          end do
        end do
      end do
    end do

    write(*,"(a,i8)") "Storing e-e integrals n_{1}l_{1}n_{3}l_{3} combination: ", this%nidx

    do bra = 1, this%nidx
      n1 = this%n1(bra)
      l1 = this%l1(bra)
      n3 = this%n2(bra)
      l3 = this%l2(bra)
      do ket = 1, this%nidx
        n2 = this%n1(ket)
        l2 = this%l1(ket)
        n4 = this%n2(ket)
        l4 = this%l2(ket)
        this%bk(bra,ket)%F = 0.d0
      end do
    end do
    NMesh = size(rmesh)
    !$omp parallel
    !$omp do private(bra, n1, l1, n3, l3, ket, n2, l2, n4, l4, integral, i1)
    do bra = 1, this%nidx
      n1 = this%n1(bra)
      l1 = this%l1(bra)
      n3 = this%n2(bra)
      l3 = this%l2(bra)
      do ket = 1, this%nidx
        n2 = this%n1(ket)
        l2 = this%l1(ket)
        n4 = this%n2(ket)
        l4 = this%l2(ket)
        integral = 0.d0
        do i1 = 1, NMesh
          integral = integral + rwmesh(i1) * &
              & rnl(i1,n1,l1) * rnl(i1,n3,l3) * rnl(i1,n2,l2) * rnl(i1,n4,l4) * (zeta/rmesh(i1))**2
        end do
        this%bk(bra,ket)%F = integral
        !!$omp critical
        !write(*,"(8i3,f12.6)") n1,l1,n2,l2,n3,l3,n4,l4,integral
        !!$omp end critical
      end do
    end do
    !$omp end do
    !$omp end parallel
  end subroutine initialize_fnl_laguerre

  function get_fnl(this, n1, l1, n2, l2, n3, l3, n4, l4) result(r)
    class(Fnl), intent(in) :: this
    integer, intent(in) :: n1, l1, n2, l2, n3, l3, n4, l4
    integer :: bra, ket
    real(8) :: r
    bra = this%idx(n1,l1,n3,l3)
    ket = this%idx(n2,l2,n4,l4)
    r = this%bk(bra,ket)%F
  end function get_fnl
end module TwoBodySpinContact
